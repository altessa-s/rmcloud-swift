// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
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
// `URLProtocol` that answers from a script. No network: the sessions are
// ephemeral and carry nothing but the handler below.

// MARK: - What a small request does with what it is handed

// `send` reads the whole body into memory and then measures it. Thirty-two
// megabytes is a line drawn far past anything the protocol has ever sent, and
// until now only a double had ever crossed it — which proved the client's
// reaction and not the transport's rule. This one crosses it for real.
@Test("A body past the ceiling is refused rather than carried upwards")
func aBodyPastTheCeilingIsRefused() async throws {
    let over = URLSessionTransport.bodyLimit + 1
    let url = ScriptedServer.expect(.init(chunks: [Data(count: over)]))
    let session = ScriptedServer.session()
    defer { session.finishTasksAndInvalidate() }

    await #expect(throws: CloudError.oversizedResponse(bytes: over, limit: URLSessionTransport.bodyLimit)) {
        _ = try await URLSessionTransport(session: session).send(URLRequest(url: url))
    }
}

// A body one byte under is the other half of the same rule: a ceiling that
// refuses everything is not a ceiling.
@Test("A body at the ceiling is still answered")
func aBodyAtTheCeilingIsAnswered() async throws {
    let url = ScriptedServer.expect(.init(chunks: [Data(count: URLSessionTransport.bodyLimit)]))
    let session = ScriptedServer.session()
    defer { session.finishTasksAndInvalidate() }

    let (data, response) = try await URLSessionTransport(session: session).send(URLRequest(url: url))
    #expect(data.count == URLSessionTransport.bodyLimit)
    #expect(response.statusCode == 200)
}

// `HTTPURLResponse` is what every caller above is promised, and the cast that
// promises it is the only thing between them and a `URLResponse` with no status
// on it. A handler answering something else is not a hypothetical — it is what
// a captive portal and any non-HTTP scheme produce.
@Test("A reply that is not HTTP is refused rather than cast away")
func aReplyThatIsNotHTTPIsRefused() async throws {
    let url = ScriptedServer.expect(.init(isHTTP: false, chunks: [Data("a reply".utf8)]))
    let session = ScriptedServer.session()
    defer { session.finishTasksAndInvalidate() }

    let error = await #expect(throws: CloudError.self) {
        _ = try await URLSessionTransport(session: session).send(URLRequest(url: url))
    }
    guard case .malformedResponse = error else {
        Issue.record("a reply with no status came back as \(String(describing: error))")
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
    func aCancelledDownloadIsTakenOffTheWire() async {
        let url = ScriptedServer.expect(.init(parks: true))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let asking = Task {
            try await router.run(
                URLRequest(url: url),
                ceiling: DownloadCeiling(limitBytes: .max),
                onProgress: { _, _ in },
                in: session
            )
        }
        await until("the request to reach the wire") { ScriptedServer.reached(url) }
        asking.cancel()

        #expect(await ScriptedServer.stops(url), "the download was abandoned rather than cancelled")
        let error = await settled(asking)
        #expect((error as? URLError)?.code == .cancelled)
    }

    // The ceiling is not a check on a finished file — `blobFile` already had one
    // of those, and a file that has been written is a container that has already
    // been filled. It is a refusal made while the bytes are still coming, and
    // the only way a delegate refuses is by taking the task down. Left out, the
    // caller gets its error and the download carries on behind it to the end.
    @Test("A body running past the ceiling is refused and the bytes stopped")
    func aBodyRunningPastTheCeilingIsStopped() async {
        // Undeclared, so the refusal can only come from what actually arrived.
        // The ceiling is crossed by the second piece; after it the server
        // holds the rest until the refusal lands, so the assertion below is
        // about the refusal reaching the wire, not about winning a race
        // against a metronome.
        let url = ScriptedServer.expect(
            .init(declaresLength: false, chunks: Self.chunks, stallsUntilStopped: 2)
        )
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
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

        #expect(await ScriptedServer.stops(url), "the refusal did not reach the wire")
        #expect(
            ScriptedServer.delivered(url) < Self.chunks.count,
            "the body ran to the end after the caller had been told no"
        )
    }

    // The declared length is read for one reason: it makes the refusal free.
    // Ignored, the ceiling still holds — but only after a ceiling's worth of a
    // body nobody wants has been written to disk.
    @Test("A declared length past the ceiling is refused before any of it arrives")
    func aDeclaredLengthIsRefusedBeforeTheBody() async {
        let url = ScriptedServer.expect(.init(chunks: Self.chunks))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
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
        let url = ScriptedServer.expect(.init(chunks: Self.chunks))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
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
        let url = ScriptedServer.expect(.init(declaresLength: false, chunks: Self.chunks))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
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
        let body = Data("the contents of an original".utf8)
        let url = ScriptedServer.expect(.init(chunks: [body]))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
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

    // The same cast as in `send`, in the one place where getting it wrong costs
    // a file as well as an answer.
    @Test("A download whose reply is not HTTP is refused")
    func aDownloadWhoseReplyIsNotHTTPIsRefused() async {
        let url = ScriptedServer.expect(.init(isHTTP: false, chunks: [Data("a reply".utf8)]))
        let router = DownloadRouter()
        let session = ScriptedServer.session(delegate: router)
        defer { session.finishTasksAndInvalidate() }

        let error = await #expect(throws: CloudError.self) {
            _ = try await router.run(
                URLRequest(url: url),
                ceiling: DownloadCeiling(limitBytes: .max),
                onProgress: { _, _ in },
                in: session
            )
        }
        guard case .malformedResponse = error else {
            Issue.record("a download with no status came back as \(String(describing: error))")
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

// MARK: - The server

/// A server that answers from a script written down before the request goes
/// out: a status, a body in as many pieces as the test wants it in, a length
/// declared or not, and a reply that is not HTTP at all.
///
/// A `URLProtocol` rather than one more `HTTPTransporting` double, for the
/// reason given at the top of this file. It is the sibling of `SilentServer`
/// next door, which answers nothing; this one answers, and slowly enough that
/// what happens to a download in the middle can be asked about.
final class ScriptedServer: URLProtocol {
    struct Script: Sendable {
        var status = 200
        /// Whether the reply carries a status at all.
        var isHTTP = true
        /// Answer a redirect to here instead of a body. The request that
        /// follows is built the way the loading system builds one — the method
        /// and every header carried over — so that what the delegate is handed
        /// is what a server's redirect really offers it.
        var redirectsTo: URL?
        /// Whether the reply says how long it is.
        var declaresLength = true
        var chunks: [Data] = []
        /// Never answer and never finish, so the only way out is the caller
        /// giving up.
        var parks = false
        /// How long to wait between pieces of the body. Without a pause the
        /// whole body is handed over before the first delegate call has been
        /// made, and nothing decided from a delegate call — a ceiling, above
        /// all — could ever arrive in time to matter.
        var pace: TimeInterval = 0.005
        /// After this many pieces, wait for the stop instead of pacing on.
        /// The pace above makes an interruption *possible*; it does not make
        /// it certain — under a loaded run the refusal lost the race to a
        /// 5 ms metronome eight times over (8 of 8 pieces
        /// delivered). A test that asserts the bytes *stopped* opts in here:
        /// the wire then behaves like a server with more to give, which only
        /// the refusal can silence. The wait is bounded, so a refusal that
        /// never comes fails the test instead of hanging it.
        var stallsUntilStopped: Int?
    }

    private struct Exchange {
        var script: Script
        var reached = false
        var delivered = 0
        var stopped = false
        /// The headers the request arrived with. The only way to ask what
        /// crossed a redirect: what the delegate handed back is not evidence
        /// that it is what went out.
        var headers: [String: String] = [:]
    }

    private static let exchanges = Mutex<[String: Exchange]>([:])

    /// Put a script behind a URL nothing else is waiting on, and hand back the
    /// URL. Requests are kept apart by URL rather than counted, because the
    /// tests here run beside one another.
    ///
    /// `host` is a parameter for one reason: a redirect that stays on the same
    /// host and one that leaves it are different rules, and only the second is
    /// the one about the token.
    static func expect(_ script: Script, host: String = "sync.invalid") -> URL {
        let url = URL.constant("https://\(host)/sync/v3/files/\(UUID().uuidString)")
        exchanges.withLock { $0[url.absoluteString] = Exchange(script: script) }
        return url
    }

    /// Whether the request got as far as this handler.
    static func reached(_ url: URL) -> Bool {
        exchanges.withLock { $0[url.absoluteString]?.reached ?? false }
    }

    /// The headers the request to this URL carried.
    static func headers(_ url: URL) -> [String: String] {
        exchanges.withLock { $0[url.absoluteString]?.headers ?? [:] }
    }

    /// How many pieces of the body went out before anybody interrupted.
    static func delivered(_ url: URL) -> Int {
        exchanges.withLock { $0[url.absoluteString]?.delivered ?? 0 }
    }

    /// Wait until the loading was called off, and say whether it was. The one
    /// sign out here that a cancellation reached the wire rather than merely
    /// releasing the caller.
    static func stops(_ url: URL) async -> Bool {
        await until("the request to be called off") {
            exchanges.withLock { $0[url.absoluteString]?.stopped ?? false }
        }
        return exchanges.withLock { $0[url.absoluteString]?.stopped ?? false }
    }

    /// A session that goes nowhere but here.
    static func session(delegate: (any URLSessionDelegate)? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedServer.self]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Everything, so that a URL nobody scripted fails here rather than
    /// falling through to the network.
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let arrived = request.allHTTPHeaderFields ?? [:]
        guard let url = request.url,
              let script = Self.exchanges.withLock({ held -> Script? in
                  guard var exchange = held[url.absoluteString] else { return nil }
                  exchange.reached = true
                  exchange.headers = arrived
                  held[url.absoluteString] = exchange
                  return exchange.script
              })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard !script.parks else { return }
        if let target = script.redirectsTo {
            redirect(from: url, to: target)
            return
        }

        // `URLProtocol` is a Foundation class from before `Sendable`, and the
        // body has to be written out from somewhere other than here:
        // `stopLoading` arrives on this same thread, so a body handed over in
        // one stretch could never be interrupted — which is the one thing a
        // ceiling does.
        nonisolated(unsafe) let me = self
        let client = self.client
        let key = url.absoluteString
        // A queue rather than a `Task`: the pause between pieces has to hold a
        // thread, and `Task.sleep` gives one back — which puts the rest of the
        // body in a queue behind whatever else the run is doing.
        DispatchQueue.global().async {
            let length = script.chunks.reduce(0) { $0 + $1.count }
            let response: URLResponse
            if script.isHTTP {
                response = HTTPURLResponse.fake(
                    script.status,
                    for: url,
                    headers: script.declaresLength ? ["Content-Length": String(length)] : [:]
                )
            } else {
                response = URLResponse(
                    url: url,
                    mimeType: "application/octet-stream",
                    expectedContentLength: script.declaresLength ? length : -1,
                    textEncodingName: nil
                )
            }
            client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            for (index, chunk) in script.chunks.enumerated() {
                if index == script.stallsUntilStopped {
                    var patience = 1000
                    while patience > 0, Self.exchanges.withLock({ $0[key]?.stopped == false }) {
                        Thread.sleep(forTimeInterval: 0.005)
                        patience -= 1
                    }
                }
                guard Self.exchanges.withLock({ $0[key]?.stopped == false }) else { return }
                client?.urlProtocol(me, didLoad: chunk)
                Self.exchanges.withLock { $0[key]?.delivered += 1 }
                Thread.sleep(forTimeInterval: script.pace)
            }
            client?.urlProtocolDidFinishLoading(me)
        }
    }

    /// Answer a 302 and hand the loading system the request that follows.
    ///
    /// The headers are copied over deliberately, the token among them. A server
    /// cannot strip what a client is about to send; whether the `Authorization`
    /// survives the hop is the client's decision, and a harness that made it
    /// here would be asserting its own tidiness rather than the delegate's rule.
    private func redirect(from url: URL, to target: URL) {
        let response = HTTPURLResponse.fake(
            302,
            for: url,
            headers: ["Location": target.absoluteString]
        )
        var following = URLRequest(url: target)
        following.httpMethod = request.httpMethod
        following.allHTTPHeaderFields = request.allHTTPHeaderFields
        client?.urlProtocol(self, wasRedirectedTo: following, redirectResponse: response)
        // The load is over as far as this instance is concerned: the system
        // starts a fresh one for the new request, and this one is asked to stop.
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Which, on this handler, only ever happens because the task was called
    /// off: nothing else takes a request away from it.
    override func stopLoading() {
        guard let key = request.url?.absoluteString else { return }
        Self.exchanges.withLock { $0[key]?.stopped = true }
    }
}
