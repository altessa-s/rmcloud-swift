// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RMCloud
import Synchronization
import Testing

// The production transport with a server under it.
//
// Everything else in the suite reaches `CloudClient` through a double standing
// in for `HTTPTransporting`, which is the right seam for the protocol and the
// wrong one for this file: a double answers from a fixture and so steps over
// every line that exists because the answer came off a socket. The ceiling that
// stops a body mid-flight, the progress that has to be reported more than once
// to be worth reporting, the temporary file that lives only until a delegate
// method returns, the reply that is not HTTP at all — none of them are things a
// double has.
//
// So these run `URLSessionTransport` and `DownloadRouter` themselves, over a
// loopback HTTP server that answers from a script. Each test owns its listener.

// MARK: - What a small request does with what it is handed

// `send` reads the whole body into memory and then measures it. Thirty-two
// megabytes is a line drawn far past anything the protocol has ever sent, and
// until now only a double had ever crossed it — which proved the client's
// reaction and not the transport's rule. This one crosses it for real.
@Test("A body past the ceiling is refused rather than carried upwards")
func aBodyPastTheCeilingIsRefused() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let over = URLSessionTransport.bodyLimit + 1
    let url = server.expect(.init(chunks: [Data(count: over)]))
    let session = server.session()
    defer { session.finishTasksAndInvalidate() }

    await #expect(throws: CloudError.oversizedResponse(bytes: over, limit: URLSessionTransport.bodyLimit)) {
        _ = try await URLSessionTransport(session: session).send(URLRequest(url: url))
    }
}

// A body one byte under is the other half of the same rule: a ceiling that
// refuses everything is not a ceiling.
@Test("A body at the ceiling is still answered")
func aBodyAtTheCeilingIsAnswered() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let url = server.expect(.init(chunks: [Data(count: URLSessionTransport.bodyLimit)]))
    let session = server.session()
    defer { session.finishTasksAndInvalidate() }

    let (data, response) = try await URLSessionTransport(session: session).send(URLRequest(url: url))
    #expect(data.count == URLSessionTransport.bodyLimit)
    #expect(response.statusCode == 200)
}

// Invalid HTTP bytes fail in URLSession before a response object can be delivered.
// The Apple-only synthetic response tests separately cover the defensive cast.
// Plain text can be accepted as an HTTP/0.9 body, so use an invalid HTTP/1.1
// status line to require a parsing failure on every backend.
private let invalidHTTPReply = Data("HTTP/1.1 not-a-status\r\n\r\na reply".utf8)

@Test("A reply that never becomes HTTP is refused by the request transport")
func invalidHTTPBytesAreRefused() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let url = server.expect(.init(isHTTP: false, chunks: []))
    let session = server.session()
    defer { session.finishTasksAndInvalidate() }

    let error = await #expect(throws: CloudError.self) {
        _ = try await URLSessionTransport(session: session).send(URLRequest(url: url))
    }
    guard case .transport = error else {
        Issue.record("a reply with no HTTP answer came back as \(String(describing: error))")
        return
    }
}

// MARK: - What a download does while it is still arriving

/// Serialised because they share the one thing this file cannot make copies of:
/// the process's own scheduling. Each has a live `URLSession` reporting from its
/// own threads, and several of them at once turn "the second report arrived" —
/// which is what half of these assert — into a question about machine load.
@Suite("A download, over the delegate that carries it", .serialized)
struct DownloadDelegateTests {
    /// Eight chunks, so that "reported more than once" is a thing the handler
    /// can actually offer.
    static let chunk = 64 << 10
    static let chunks = Array(repeating: Data(count: chunk), count: 8)
    static let bodyLength = Int64(chunk * 8)

    // The third of the three operations, and the one whose cancellation nobody
    // had ever asked about. `send` and `upload` are covered next door; this one
    // hands its task to `withTaskCancellationHandler` in a different file and a
    // different type, and a handler that stops cancelling is invisible — the
    // caller returns either way, having merely stopped waiting, while the bytes
    // go on arriving into the extension's container.
    @Test("A download the caller gave up on is taken off the wire")
    func aCancelledDownloadIsTakenOffTheWire() async throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let url = server.expect(.init(parks: true))
        let router = DownloadRouter()
        let session = server.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let asking = Task {
            try await router.run(
                URLRequest(url: url),
                ceiling: DownloadCeiling(limitBytes: .max),
                onProgress: { _, _ in },
                in: session
            )
        }
        await until("the request to reach the wire") { server.reached(url) }
        asking.cancel()

        #expect(await server.stops(url), "the download was abandoned rather than cancelled")
        let error = await settled(asking)
        #expect((error as? URLError)?.code == .cancelled)
    }

    // The ceiling is not a check on a finished file — `blobFile` already had one
    // of those, and a file that has been written is a container that has already
    // been filled. It is a refusal made while the bytes are still coming, and
    // the only way a delegate refuses is by taking the task down. Left out, the
    // caller gets its error and the download carries on behind it to the end.
    @Test("A body running past the ceiling is refused and the bytes stopped")
    func aBodyRunningPastTheCeilingIsStopped() async throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        // Undeclared, so the refusal can only come from what actually arrived.
        // The ceiling is crossed by the second piece; after it the server
        // holds the rest until the refusal lands, so the assertion below is
        // about the refusal reaching the wire, not about winning a race
        // against a metronome.
        let url = server.expect(
            .init(declaresLength: false, chunks: Self.chunks, stallsUntilStopped: 2)
        )
        let router = DownloadRouter()
        let session = server.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let limit = Int64(Self.chunk) + 1
        let error = await #expect(throws: CloudError.self) {
            _ = try await router.run(
                URLRequest(url: url),
                ceiling: DownloadCeiling(limitBytes: limit),
                onProgress: { _, _ in },
                in: session
            )
        }
        guard case .oversizedResponse(let bytes, let refusedAt) = error else {
            Issue.record("an overrunning body came back as \(String(describing: error))")
            return
        }
        #expect(refusedAt == Int(limit))
        #expect(Int64(bytes) > limit, "the refusal named a size that was within the ceiling")

        #expect(await server.stops(url), "the refusal did not reach the wire")
        #expect(
            server.delivered(url) < Self.chunks.count,
            "the body ran to the end after the caller had been told no"
        )
    }

    // The declared length is read for one reason: it makes the refusal free.
    // Ignored, the ceiling still holds — but only after a ceiling's worth of a
    // body nobody wants has been written to disk.
    @Test("A declared length past the ceiling is refused before any of it arrives")
    func aDeclaredLengthIsRefusedBeforeTheBody() async throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let url = server.expect(.init(chunks: Self.chunks))
        let router = DownloadRouter()
        let session = server.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let reports = Mutex<[(Int64, Int64)]>([])
        // Above a chunk, so nothing that has actually arrived can account for
        // the refusal: only the declaration can.
        let limit = Int64(Self.chunk) * 2
        let error = await #expect(throws: CloudError.self) {
            _ = try await router.run(
                URLRequest(url: url),
                ceiling: DownloadCeiling(limitBytes: limit),
                onProgress: { written, expected in reports.withLock { $0.append((written, expected)) } },
                in: session
            )
        }
        #expect(
            error == .oversizedResponse(bytes: Int(Self.bodyLength), limit: Int(limit)),
            "the refusal was made on the bytes that had arrived, not on the length declared"
        )
        #expect(reports.withLock { $0 }.isEmpty, "a refused download still drove a progress bar")
    }

    // The bar next to the file in Finder is the whole reason downloads are not
    // just `send` with a bigger buffer. One report at the end would satisfy any
    // assertion about the final value and would be exactly the behaviour this
    // path was written to avoid.
    @Test("A download reports its progress while it arrives, not once at the end")
    func aDownloadReportsWhileItArrives() async throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let url = server.expect(.init(chunks: Self.chunks))
        let router = DownloadRouter()
        let session = server.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let reports = Mutex<[(Int64, Int64)]>([])
        let (file, _) = try await router.run(
            URLRequest(url: url),
            ceiling: DownloadCeiling(limitBytes: .max),
            onProgress: { written, expected in reports.withLock { $0.append((written, expected)) } },
            in: session
        )
        defer { try? FileManager.default.removeItem(at: file) }

        let seen = reports.withLock { $0 }
        #expect(seen.count > 1, "the whole download was reported in one go: \(seen)")
        #expect(seen.map(\.0) == seen.map(\.0).sorted(), "the count of arrived bytes went backwards")
        #expect(seen.last?.0 == Self.bodyLength)
        #expect(seen.allSatisfy { $0.1 == Self.bodyLength }, "the declared length was not passed on")
    }

    // A length nobody declared arrives as `-1`, and a progress bar handed `-1`
    // to fill up to is a progress bar drawn backwards. The floor is the whole of
    // what the caller is promised: no total, rather than a nonsensical one.
    @Test("An undeclared length is reported as no total rather than as a negative one")
    func anUndeclaredLengthIsReportedAsNoTotal() async throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let url = server.expect(.init(declaresLength: false, chunks: Self.chunks))
        let router = DownloadRouter()
        let session = server.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let reports = Mutex<[(Int64, Int64)]>([])
        let (file, _) = try await router.run(
            URLRequest(url: url),
            ceiling: DownloadCeiling(limitBytes: .max),
            onProgress: { written, expected in reports.withLock { $0.append((written, expected)) } },
            in: session
        )
        defer { try? FileManager.default.removeItem(at: file) }

        let seen = reports.withLock { $0 }
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0.1 == 0 }, "an undeclared length was passed on as it arrived: \(seen)")
        #expect(seen.last?.0 == Self.bodyLength)
    }

    // `URLSession` stages the download in a file of its own and deletes it the
    // moment `didFinishDownloadingTo` returns. The caller is handed the URL
    // some way after that — it is a continuation resumed from inside that
    // method — so a download that forgot to claim the file hands back a path to
    // nothing, and does it intermittently, which is worse.
    @Test("A finished download hands over a file that outlives the delegate")
    func aFinishedDownloadHandsOverAFileThatLives() async throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let body = Data("the contents of an original".utf8)
        let url = server.expect(.init(chunks: [body]))
        let router = DownloadRouter()
        let session = server.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let (file, response) = try await router.run(
            URLRequest(url: url),
            ceiling: DownloadCeiling(limitBytes: .max),
            onProgress: { _, _ in },
            in: session
        )
        defer { try? FileManager.default.removeItem(at: file) }

        // Slept rather than polled: what is waited for is the staged file being
        // taken away, and an unclaimed one is taken away at a moment nothing out
        // here can observe. A condition that is true now and false in a
        // millisecond cannot be spun on — it has to be outlived.
        try await Task.sleep(for: .milliseconds(200))

        #expect(response.statusCode == 200)
        #expect(FileManager.default.fileExists(atPath: file.path()), "the file went with the delegate")
        #expect(try Data(contentsOf: file) == body)
    }

    // A socket cannot synthesize a non-HTTP URLResponse: URLSession can accept
    // garbage or an empty reply as a download. Closing before the declared body
    // arrives makes the reply unusable on every backend.
    @Test("A reply that breaks off in the body is refused by the download transport")
    func aDownloadBodyThatBreaksOffIsRefused() async throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        let url = server.expect(.init(
            status: 200,
            isHTTP: true,
            chunks: [Data("short body".utf8)],
            headers: ["Content-Length": "100"]
        ))
        let router = DownloadRouter()
        let session = server.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let error = await #expect(throws: CloudError.self) {
            _ = try await router.run(
                URLRequest(url: url),
                ceiling: DownloadCeiling(limitBytes: .max),
                onProgress: { _, _ in },
                in: session
            )
        }
        guard case .transport = error else {
            Issue.record("a download with an incomplete body came back as \(String(describing: error))")
            return
        }
    }
}

// MARK: - Waiting

/// What a task came back with, or `nil` if it came back with nothing.
///
/// `await task.value` would do were these tests about anything else. They are
/// about a cancellation reaching a live `URLSession` task, and a cancellation
/// handler that has stopped working leaves the continuation unresumed for good:
/// awaited directly, the broken case hangs the whole run instead of failing it.
private func settled<T: Sendable>(_ task: Task<T, any Error>) async -> (any Error)? {
    let held = Mutex<(done: Bool, error: (any Error)?)>((false, nil))
    let watching = Task {
        do {
            _ = try await task.value
            held.withLock { $0 = (true, nil) }
        } catch {
            held.withLock { $0 = (true, error) }
        }
    }
    await until("the request to come back") { held.withLock { $0.done } }
    watching.cancel()
    return held.withLock { $0.error }
}
