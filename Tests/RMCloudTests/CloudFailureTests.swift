// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Synchronization
import Testing

// What happens when the cloud says no.
//
// The happy paths were covered from the start; these are the ones where being
// wrong is expensive and nothing crashes to say so. A token the server has
// taken back, a walk over the library cut short by an outage, an index that
// lost a line on the way, a quarter-gigabyte left in the temporary directory,
// a socket that will not come up.

/// A synthetic JWT. Only the middle is ever parsed; the header and the
/// signature are decoration. Real tokens never appear in tests.
private func token(expiringAt seconds: Int) -> String {
    syntheticToken(claims: #"{"exp": \#(seconds)}"#)
}

/// A blob and the hash it is addressed by, so a fixture cannot disagree with
/// itself.
private func blob(_ text: String) -> (body: String, hash: String) {
    (text, ContentHash.blob(Data(text.utf8)))
}

// MARK: - A token the server has taken back

// A revoked token is still perfectly fresh by its own `exp`, and the store
// outlives the process. Dropping only the actor's copy meant the retry read
// the same token back out of the Keychain and sent it again — the second 401
// went uncaught, and nothing mended the account until the token expired on its
// own, hours later.
@Test("A refused token is not fetched straight back out of the store")
func aRefusedTokenIsNotReadBackFromTheStore() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let refused = token(expiringAt: 4_102_444_800)      // 2100
    try secrets.save(refused, as: .userToken)
    let replacement = token(expiringAt: 4_102_444_801)

    let payload = "the document"
    let transport = ScriptedTransport([
        .init(status: 401),                              // the read, with the stored token
        .init(body: replacement),                        // the exchange it forces
        .init(body: payload),                            // the read again
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    let data = try await client.blob(hash: ContentHash.blob(Data(payload.utf8)), name: "doc.pdf")

    #expect(String(decoding: data, as: UTF8.self) == payload)
    #expect(transport.requests.count == 3, "the refusal did not cost a new token")
    let sent = transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
    #expect(sent.first == "Bearer \(refused)")
    #expect(sent.last == "Bearer \(replacement)", "the retry went out with the refused token")
    #expect(try secrets.secret(.userToken) == replacement)
}

// The other half of the same rule: a token another process bought while we
// were being refused has to survive. Marking the value rather than deleting
// the record is what keeps it — several processes share this Keychain group,
// and a blind delete costs whichever of them was innocent a needless exchange.
@Test("Invalidating remembers which token was refused, not that there was one")
func invalidatingSparesATokenBoughtElsewhere() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let refused = token(expiringAt: 4_102_444_800)
    try secrets.save(refused, as: .userToken)

    let transport = ScriptedTransport([])
    let tokens = TokenProvider(transport: transport, secrets: secrets)
    #expect(try await tokens.userToken() == refused)

    await tokens.invalidateUserToken(refused)
    // Another process replaces the record between the refusal and the retry.
    let bought = token(expiringAt: 4_102_444_802)
    try secrets.save(bought, as: .userToken)

    #expect(try await tokens.userToken() == bought)
    #expect(transport.requests.isEmpty, "a good token in the store still cost an exchange")
}

// The other other half: a refusal names the token it was refused for. This
// actor is reentrant and `LibraryLoader` runs its requests side by side, so an
// expired token is refused on several at once — and the second refusal gets
// back after the first has already bought the replacement. Told only "drop
// what you have", it dropped that replacement and marked it rejected, so the
// next call read the fresh token out of the store, recognised it as the
// refused one and bought a third: the method that exists to spare an exchange
// causing one, which is how a recovery earns a 429.
@Test("A refusal about an old token does not discard the one bought since")
func aLateRefusalSparesTheReplacement() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let expired = token(expiringAt: 4_102_444_800)
    try secrets.save(expired, as: .userToken)
    let replacement = token(expiringAt: 4_102_444_801)
    let transport = ScriptedTransport([.init(body: replacement)])

    let tokens = TokenProvider(transport: transport, secrets: secrets)
    #expect(try await tokens.userToken() == expired)

    // The first 401 lands and buys the replacement.
    await tokens.invalidateUserToken(expired)
    #expect(try await tokens.userToken() == replacement)

    // The second — about the same dead token, from the request that went out
    // beside the first — arrives once the replacement is already in hand.
    await tokens.invalidateUserToken(expired)

    #expect(try await tokens.userToken() == replacement, "the replacement was thrown away")
    #expect(transport.requests.count == 1, "the late refusal cost a second exchange")
}

// A fast path answering from `cachedAt` alone would mean twenty hours from
// whenever the token entered memory, whatever the token itself said. A token
// inherited from the store with six minutes left would therefore be good for twenty
// hours — every request after the sixth minute a 401.
@Test("A token in memory is judged by its own expiry, not by how long we have held it")
func theMemoryCacheHonoursTheTokenExpiry() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    // Alive at the epoch, spent ten minutes later — well inside the twenty
    // hours the age-based path would have allowed.
    let shortLived = token(expiringAt: 600)
    let replacement = token(expiringAt: 4_102_444_800)
    try secrets.save(shortLived, as: .userToken)

    let clock = Mutex(Date(timeIntervalSince1970: 0))
    let transport = ScriptedTransport([.init(body: replacement)])
    let tokens = TokenProvider(
        transport: transport,
        secrets: secrets,
        now: { clock.withLock { $0 } }
    )

    #expect(try await tokens.userToken() == shortLived)
    clock.withLock { $0 = Date(timeIntervalSince1970: 500) }
    #expect(try await tokens.userToken() == replacement, "a spent token was handed out again")
}

// MARK: - A walk that must not finish quietly

// The line the walk draws, in one place and without a network.
@Test("Only a document's own faults are skippable")
func onlyDocumentFaultsAreSkippable() {
    #expect(CloudError.malformedIndex(line: "x", reason: "y").isDocumentLocal)
    #expect(CloudError.unsupportedSchema("9").isDocumentLocal)
    #expect(CloudError.hashMismatch(expected: "a", actual: "b").isDocumentLocal)
    #expect(CloudError.missingHash(name: "doc").isDocumentLocal)
    // Debris: the record points at something the storage does not have.
    #expect(CloudError.http(status: 404, path: "/x").isDocumentLocal)

    #expect(!CloudError.transport(code: -1009).isDocumentLocal)
    #expect(!CloudError.rateLimited(retryAfter: 1).isDocumentLocal)
    #expect(!CloudError.unauthorized.isDocumentLocal)
    #expect(!CloudError.http(status: 503, path: "/x").isDocumentLocal)
    #expect(!CloudError.http(status: 500, path: "/x").isDocumentLocal)
}

// MARK: - An index that lost a line

// Dropping the v4 count line on sight, checked only for being there
// at all, loses an index's first real record —
// silently, and in `.editing` for good: the writer re-serialises the list it
// parses and puts it back, so the record vanishes from the cloud.
@Test("A v4 index with no count line is refused, not quietly shortened")
func aV4IndexWithoutItsCountLineIsRefused() {
    let missing = """
        4
        aa:80000000:doc-1:1:100
        bb:80000000:doc-2:1:100

        """
    #expect(throws: CloudError.self) { try IndexParser.parse(missing) }

    // The same records with the line in place: both survive.
    let whole = """
        4
        0:.:2:200
        aa:80000000:doc-1:1:100
        bb:80000000:doc-2:1:100

        """
    let index = try? IndexParser.parse(whole)
    #expect(index?.entries.map(\.documentID) == ["doc-1", "doc-2"])
}

// The count itself stays advisory: losing the whole library over a number that
// disagrees is worse than showing the library as it is. What changed is that
// the disagreement is noticed at all — it goes to the log.
@Test("A count that disagrees is still not fatal")
func aDisagreeingCountIsNotFatal() throws {
    let index = try IndexParser.parse("""
        4
        0:.:7:200
        aa:80000000:doc-1:1:100

        """)
    #expect(index.entries.count == 1)
}

// A line of the right shape but impossible contents is not a header.
@Test("A count line with impossible numbers is not a count line")
func animpossibleCountIsNotAHeader() {
    #expect(throws: CloudError.self) {
        try IndexParser.parse("4\n0:.:-1:200\naa:80000000:doc-1:1:100\n")
    }
    #expect(throws: CloudError.self) {
        try IndexParser.parse("4\n0:.:1:-200\naa:80000000:doc-1:1:100\n")
    }
    // Four fields, but not starting with the type every count line starts with.
    #expect(throws: CloudError.self) {
        try IndexParser.parse("4\nzz:.:1:200\naa:80000000:doc-1:1:100\n")
    }
}

// MARK: - A download nobody wants any more

// The file is ours from the moment the download claims it, and nothing sweeps
// the temporary directory behind us. Hashing fails on cancellation — which the
// file provider does freely — and only a hash mismatch cleans up after
// itself; without that, an abandoned original is hundreds of megabytes inside the
// extension's container.
@Test("A download whose hashing is cancelled leaves nothing behind")
func aCancelledDownloadLeavesNoFile() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    // A token with life left in it, so nothing but the download is asked for.
    try secrets.save(token(expiringAt: 4_102_444_800), as: .userToken)

    // A directory of the test's own: the shared temporary directory is full of
    // other tests' work, and counting what is left in it there proves nothing.
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "rmcloud-cancelled-download-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = Data(String(repeating: "page", count: 4096).utf8)
    let transport = DownloadingTransport(directory: directory, body: payload)
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    let hash = ContentHash.blob(payload)
    let task = Task {
        try await client.blobFile(hash: hash, name: "doc.pdf")
    }
    // Cancelled before it is ever awaited: the download still runs — the
    // double does not check — and the hashing after it does, which is the exit
    // that would otherwise keep the file.
    task.cancel()
    await #expect(throws: (any Error).self) { _ = try await task.value }

    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path())
    #expect(left.isEmpty, "the claimed file outlived the download: \(left)")
}

// MARK: - A request the caller gave up on

// Everything `URLSession` throws arrives as a `URLError`. Carrying every one of
// them outwards as `CloudError.transport` — the cancellation included — turns
// `-999` into `SyncError.offline`, so a `Progress` the system
// had itself cancelled comes back to `fileproviderd` as an unreachable server:
// retries against a request nobody wants any more, and an error drawn over the
// user's own decision. The extension has recognised a cancellation from the
// start; it was the transport that stopped handing one over.
@Test("A cancellation stays one, and every other code stays a network failure")
func aCancellationIsNotANetworkFailure() {
    let calledOff = transportFailure(URLError(.cancelled))
    #expect(calledOff as? CloudError == nil, "a cancellation was renamed a network failure")
    #expect((calledOff as? URLError)?.code == .cancelled)

    // The rest are what the case exists for, and they are untouched.
    #expect(
        transportFailure(URLError(.notConnectedToInternet)) as? CloudError
            == .transport(code: URLError.notConnectedToInternet.rawValue)
    )
    #expect(
        transportFailure(URLError(.timedOut)) as? CloudError
            == .transport(code: URLError.timedOut.rawValue)
    )
}

// The rule above proves little on its own: what matters is that the real
// transport reaches it, and that `URLSession` really does answer a task called
// off with the error the rule is written about. A double standing in for
// `HTTPTransporting` would step over exactly the line in question, so these two
// go through `URLSessionTransport` itself, with a handler underneath that
// answers nothing at all.
@Test("A GET the caller gave up on comes back as a cancellation")
func aCancelledGetComesBackAsACancellation() async {
    let url = SilentServer.url()
    let transport = URLSessionTransport(session: SilentServer.session())

    let asking = Task { _ = try await transport.send(URLRequest(url: url)) }
    await until("the request to reach the wire") { SilentServer.isParked(url) }
    asking.cancel()

    let error = await #expect(throws: (any Error).self) { try await asking.value }
    #expect(error as? CloudError == nil, "a cancelled GET was reported as a network failure")
    #expect((error as? URLError)?.code == .cancelled)
}

@Test("An upload the caller gave up on comes back as a cancellation")
func aCancelledUploadComesBackAsACancellation() async throws {
    let url = SilentServer.url()
    let file = FileManager.default.temporaryDirectory
        .appending(path: "rmcloud-cancelled-upload-\(UUID().uuidString)")
    try Data("a document".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let transport = URLSessionTransport(session: SilentServer.session())
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"

    let sending = Task { _ = try await transport.upload(request, fromFile: file) { _, _ in } }
    await until("the body to reach the wire") { SilentServer.isParked(url) }
    sending.cancel()

    let error = await #expect(throws: (any Error).self) { try await sending.value }
    #expect(error as? CloudError == nil, "a cancelled upload was reported as a network failure")
    #expect((error as? URLError)?.code == .cancelled)
}

// MARK: - A document nobody is waiting for any more

// The hash and the checksum are two full passes over the file, and they run in
// a task of their own: taken on the actor they were passes the whole client
// stood still for — no download, no root read, nothing else this process asks
// of the cloud — while one upload spans a document of up to half a
// gigabyte. A detached task inherits no cancellation, though, so the caller's
// has to be handed over by hand. Without that hand-over the measuring grinds
// on through a file nobody wants, and the document goes out after it.
@Test("An upload nobody is waiting for stops measuring its file")
func aCancelledUploadStopsMeasuring() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    // A token with life left in it, so nothing but the upload is asked for.
    try secrets.save(token(expiringAt: 4_102_444_800), as: .userToken)

    // Large enough that measuring it cannot be over before the cancel lands:
    // the checksum alone touches every one of these bytes in Swift.
    let file = FileManager.default.temporaryDirectory
        .appending(path: "rmcloud-abandoned-upload-\(UUID().uuidString)")
    try Data(count: 16 << 20).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let transport = UnusedTransport()
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    let sending = Task { try await client.upload(contentsOf: file, name: "doc.pdf") }
    // Cancelled before it is ever awaited, the way the file provider abandons
    // work it has changed its mind about.
    sending.cancel()

    await #expect(throws: CancellationError.self) { _ = try await sending.value }
    #expect(
        transport.visits.isEmpty,
        "the document went out after the caller had gone: \(transport.visits)"
    )
}

// MARK: - What a response code means

// One table, because one reading of the status now serves both transports:
// requests throw what it returns, the websocket keeps its handshake error when
// it returns nothing. Before they were two copies of the same switch, and the
// success branch of the request side was never exercised at all — a mapping
// that answered "refused" to a 204 would have gone unnoticed.

/// A status and what the protocol should make of it.
private struct StatusReading: Sendable, CustomStringConvertible {
    let status: Int
    var retryAfter: String?
    let expected: CloudError?

    var description: String {
        let header = retryAfter.map { " (Retry-After: \($0))" } ?? ""
        return "\(status)\(header)"
    }
}

private func response(_ status: Int, retryAfter: String?) -> HTTPURLResponse {
    HTTPURLResponse.fake(
        status,
        for: URL.constant("https://example.invalid/sync/v3/files/abc"),
        headers: retryAfter.map { ["Retry-After": $0] } ?? [:]
    )
}

@Test(
    "A response code reads the same for every caller",
    arguments: [
        StatusReading(status: 200, expected: nil),
        StatusReading(status: 204, expected: nil),
        StatusReading(status: 401, expected: .unauthorized),
        StatusReading(status: 403, expected: .unauthorized),
        StatusReading(status: 404, expected: .http(status: 404, path: "/sync/v3/files/abc")),
        StatusReading(status: 409, expected: .http(status: 409, path: "/sync/v3/files/abc")),
        StatusReading(status: 412, expected: .http(status: 412, path: "/sync/v3/files/abc")),
        StatusReading(status: 429, expected: .rateLimited(retryAfter: nil)),
        StatusReading(status: 429, retryAfter: "3", expected: .rateLimited(retryAfter: 3)),
        StatusReading(status: 500, expected: .http(status: 500, path: "/sync/v3/files/abc")),
    ]
)
private func aResponseCodeReadsTheSameForEveryCaller(_ reading: StatusReading) {
    #expect(CloudError.fromHTTP(response(reading.status, retryAfter: reading.retryAfter)) == reading.expected)
}

// Registration is the one caller for which a 401 is not a stale token but a
// mistyped code, and it says so at the call site rather than by re-reading the
// status itself.
@Test("A caller may name what 401 means to it")
func aCallerMayNameWhatUnauthorizedMeansToIt() {
    let refused = response(401, retryAfter: nil)
    #expect(CloudError.fromHTTP(refused, unauthorizedAs: .invalidOneTimeCode) == .invalidOneTimeCode)
    #expect(
        CloudError.fromHTTP(response(403, retryAfter: nil), unauthorizedAs: .invalidOneTimeCode)
            == .invalidOneTimeCode
    )
    // The naming reaches no further than 401 and 403.
    #expect(
        CloudError.fromHTTP(response(500, retryAfter: nil), unauthorizedAs: .invalidOneTimeCode)
            == .http(status: 500, path: "/sync/v3/files/abc")
    )
}

// MARK: - A socket that will not come up

// `URLSession` answers `-1011` for every failed websocket upgrade — 401, 403,
// a 500, a proxy's page, anything that is not `101`. Reading that code as a
// 401 threw a good user token away on every reconnect while the service was
// merely unwell, and buying a new one each time is how the recovery earned
// itself a 429. It cut both ways: a real 401 was indistinguishable from a dead
// server, so neither could be reported for what it was.
@Test("A refused handshake is read from its status, not from the URL error code")
func aRefusedHandshakeIsReadFromItsStatus() throws {
    func refusal(_ status: Int) -> (any Error)? {
        let response = HTTPURLResponse.fake(
            status,
            for: URL.constant("https://example.invalid/notifications")
        )
        return URLSessionWebSocket.refusal(URLError(.badServerResponse), response: response)
    }

    #expect(refusal(401) as? CloudError == .unauthorized)
    #expect(refusal(403) as? CloudError == .unauthorized)
    #expect(refusal(500) as? CloudError == .http(status: 500, path: "/notifications"))
    #expect(refusal(404) as? CloudError == .http(status: 404, path: "/notifications"))
    if case .rateLimited = refusal(429) as? CloudError {} else {
        Issue.record("a 429 handshake is a rate limit, not a bad response")
    }

    // No HTTP reply at all: the connection never got that far.
    let offline = URLSessionWebSocket.refusal(URLError(.notConnectedToInternet), response: nil)
    #expect(offline as? CloudError == .transport(code: URLError.notConnectedToInternet.rawValue))
}

// The reconnect loop end to end and without a network: refused once for the
// token, connected on the second attempt, one backoff in between.
@Test("A socket refused for its token reconnects with a new one")
func theStreamReconnectsAfterARefusedToken() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    try secrets.save(token(expiringAt: 4_102_444_800), as: .userToken)
    let transport = ScriptedTransport([.init(body: token(expiringAt: 4_102_444_801))])

    let frame = NotificationFrame.text(#"{"message":{"attributes":{"event":"SyncComplete"}}}"#)
    let sockets = ScriptedSockets([.failure(CloudError.unauthorized), .success([frame])])
    let sleeper = RecordingSleeper()
    let (signals, feed) = AsyncStream<NotificationSignal>.makeStream()

    let stream = NotificationStream(
        tokens: TokenProvider(transport: transport, secrets: secrets),
        sockets: sockets,
        sleeper: sleeper,
        onSignal: { feed.yield($0) }
    )
    await stream.start()
    // Starting twice is a no-op, and the watcher does it: a wake can arrive
    // while the stream is already up.
    await stream.start()

    var seen: [String] = []
    for await signal in signals {
        switch signal {
        case .dropped: seen.append("dropped")
        case .connected: seen.append("connected")
        case .event(let event): seen.append(event.event ?? "unnamed")
        case .unreadableFrame: seen.append("unreadable")
        }
        if seen.last == "SyncComplete" { break }
    }
    await stream.stop()

    #expect(seen == ["dropped", "connected", "SyncComplete"])
    #expect(sockets.attempts == 2, "the second attempt is the whole point")
    #expect(sleeper.delays.count == 1, "one backoff between the two attempts")
    // The refusal cost exactly one exchange: the stored token was the refused
    // one, so the second attempt could not reuse it.
    #expect(transport.requests.count == 1)
}

/// What a signal is called, so a test can read the stream's account of itself.
private func name(_ signal: NotificationSignal) -> String {
    switch signal {
    case .connected: "connected"
    case .dropped: "dropped"
    case .event(let event): event.event ?? "unnamed"
    case .unreadableFrame: "unreadable"
    }
}

/// What the stream said about itself, in the order it said it. A box rather
/// than a bare `Mutex` because a `Mutex` is noncopyable and this is returned.
final class SignalLog: Sendable {
    private let entries = Mutex<[String]>([])

    var all: [String] { entries.withLock { $0 } }

    func record(_ signal: NotificationSignal) {
        entries.withLock { $0.append(name(signal)) }
    }
}

/// The stream, a factory whose handshakes park, and somewhere to collect what
/// the stream says about itself.
private func parkedStream() throws -> (NotificationStream, ParkingSockets, SignalLog) {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    try secrets.save(token(expiringAt: 4_102_444_800), as: .userToken)

    let sockets = ParkingSockets()
    let seen = SignalLog()
    let stream = NotificationStream(
        tokens: TokenProvider(transport: ScriptedTransport([]), secrets: secrets),
        sockets: sockets,
        sleeper: RecordingSleeper(),
        onSignal: { seen.record($0) }
    )
    return (stream, sockets, seen)
}

// A handshake is a round trip, and cancelling only asks. `stop()` returning
// the moment it had asked — handle cleared, nothing waited for — lets an
// attempt still inside the upgrade come back afterwards to a stream nobody is
// listening to, report itself connected and hold the connection open.
@Test("A stopped stream neither reports itself connected nor leaves its socket open")
func stoppingWaitsForTheHandshakeItCancelled() async throws {
    let (stream, sockets, seen) = try parkedStream()

    await stream.start()
    await sockets.untilStarted(1)

    // The stop waits for the run, and the run is inside the handshake: it goes
    // in a task of its own so that the gate is opened after the cancel has
    // landed rather than in a race with it.
    let stopping = Task { await stream.stop() }
    await sockets.untilCancelled(1)
    sockets.release(1)
    await stopping.value

    #expect(seen.all.isEmpty, "a stream that had been stopped still spoke")
    let opened = sockets.sockets
    try #require(opened.count == 1)
    #expect(opened[0].isClosed, "the late handshake's socket outlived the stop")
}

// The watcher drives `stop`/`start` off Wi-Fi coming and going, so the two
// arrive close together. With the handle cleared before the run was gone, the
// second run started while the first was still in its handshake, and the two
// shared one `socket` property: the late arrival closed what it found there —
// the live connection — and sent a stream that had just come up round the
// backoff for nothing.
@Test("The run that replaces a stopped one keeps its own socket")
func aRestartedRunKeepsItsOwnSocket() async throws {
    let (stream, sockets, seen) = try parkedStream()

    await stream.start()
    await sockets.untilStarted(1)
    let stopping = Task { await stream.stop() }
    await sockets.untilCancelled(1)
    sockets.release(1)
    await stopping.value

    await stream.start()
    await sockets.untilStarted(2)
    sockets.release(2)
    await until("the new run to report itself") { seen.all.contains("connected") }

    let opened = sockets.sockets
    try #require(opened.count == 2)
    #expect(opened[0].isClosed, "the stopped run walked away from its own socket")
    #expect(!opened[1].isClosed, "the stopped run closed the new run's socket")

    await stream.stop()
}

// MARK: - The wait inside the handshake

// The handshake's ping is waited for on a continuation, and a continuation is
// not a cancellation point: nothing but failing the ping can end that wait. Left
// without a cancellation handler it ran to `URLSession`'s own timeout — up to a
// minute on an upgrade nobody answers — which is the wait
// `NotificationStream.stop()` now sits behind on its way to erasing an account.
//
// `URLSessionWebSocket.connect` cannot be reached from a test: it is below
// `WebSocketConnecting`, the port the doubles above replace, and wants a live
// `URLSession`. So the wait itself is the seam, over the two things it actually
// uses.
@Test("A handshake ends with its ping, whichever way the ping goes")
func aHandshakeEndsWithItsPing() async throws {
    let good = ScriptedPing()
    let coming = Task { try await awaitPong(from: good) }
    await until("the ping to go out") { good.isPinging }
    good.answer(nil)
    try await coming.value

    let bad = ScriptedPing()
    let refused = Task { try await awaitPong(from: bad) }
    await until("the ping to go out") { bad.isPinging }
    bad.answer(CloudError.transport(code: -1011))

    await #expect(throws: CloudError.transport(code: -1011)) { try await refused.value }
    #expect(bad.cancels == 0, "an ordinary refusal closed the socket behind the caller's back")
}

// The defect itself: a caller that gives up has to be let go, and the only way
// to let it go is to fail the ping it is waiting on.
@Test("A handshake nobody is waiting for any more stops waiting")
func aCancelledHandshakeStopsWaiting() async {
    let probe = ScriptedPing()
    let coming = Task { try await awaitPong(from: probe) }
    await until("the ping to go out") { probe.isPinging }

    coming.cancel()
    await until("the cancel to reach the socket") { probe.cancels > 0 }
    // Answered whatever happened above, so that a seam which has lost its
    // cancellation handler fails the assertion rather than hanging the run.
    probe.answer(URLError(.cancelled))

    await #expect(throws: (any Error).self) { try await coming.value }
}

// The two land on top of each other in the one case this exists for: the ping
// comes back at the moment the caller gives up. Only the ping's own answer may
// resume the wait — a cancellation handler that resumed as well would be a
// second resume of a `CheckedContinuation`, which traps and takes the whole run
// with it. That trap is the assertion; there is nothing to write down.
@Test("A ping answering as the wait is cancelled resumes it exactly once")
func aPingRacingCancellationResumesOnce() async {
    // Repeated because once is not a race: the answer and the cancel have to
    // arrive together, and they do so at their own pace.
    for _ in 0..<200 {
        let probe = ScriptedPing()
        let coming = Task { try await awaitPong(from: probe) }
        await until("the ping to go out") { probe.isPinging }

        let answering = Task.detached { probe.answer(nil) }
        let cancelling = Task.detached { coming.cancel() }
        await answering.value
        await cancelling.value

        // One outcome, whichever it turned out to be. That there was one is
        // the whole of the point.
        _ = try? await coming.value
    }
}

// MARK: - One token bought between everybody who wants one

// `CloudClient` is a reentrant actor and `LibraryLoader` walks the tree with its
// requests side by side, so N of them miss the cache in the same moment. Without
// coalescing, each would buy a token of its own — N exchanges back to back, which is the
// request the service counts most tightly and how a recovery earns itself the
// 429 the rest of this file is written against.
@Test("Callers who all want a token at once buy one between them")
func concurrentCallersShareOneExchange() async throws {
    let secrets = CountingSecrets()
    try secrets.save("device", as: .deviceToken)
    let bought = token(expiringAt: 4_102_444_800)
    let transport = GatedTransport(body: bought)
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    let askers = (0..<8).map { _ in Task { try await tokens.userToken() } }
    // Everybody is in before anybody is answered. Looking in the store is the
    // last thing a caller does before it either joins the exchange or starts
    // one, and it is the only step visible from out here. Without the wait the
    // first caller could simply finish and the rest read its token out of the
    // cache, which proves nothing about sharing.
    await until("every caller to look in the store") { secrets.reads(.userToken) == 8 }
    await until("the exchange to reach the transport") { transport.requests.count == 1 }
    transport.release()

    var got: [String] = []
    for asker in askers { got.append(try await asker.value) }

    #expect(got == Array(repeating: bought, count: 8))
    #expect(transport.requests.count == 1, "each caller bought a token of its own")
}

// The exchange belongs to everybody waiting on it, not to whoever asked first —
// which is why it is an unstructured task rather than a child of that caller.
// In the extension the first caller is routinely a Finder request that gives up,
// and a child would go down with it, taking the token the others are still
// waiting for.
@Test("A caller who gives up mid-exchange takes nobody else's token with it")
func aDepartingWaiterDoesNotBreakTheExchange() async throws {
    let secrets = CountingSecrets()
    try secrets.save("device", as: .deviceToken)
    let bought = token(expiringAt: 4_102_444_800)
    let transport = GatedTransport(body: bought)
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    // The one who starts the exchange is the one who then walks away: the worst
    // case, because the exchange runs in that caller's own task.
    let leaving = Task { try await tokens.userToken() }
    await until("the exchange to reach the transport") { transport.requests.count == 1 }
    let staying = Task { try await tokens.userToken() }
    await until("the second caller to join") { secrets.reads(.userToken) == 2 }
    leaving.cancel()

    // Wait until the exchange has gone round the gate again *since* the cancel:
    // made a child of the caller who left, that is the lap on which it would
    // have thrown instead. Releasing straight after the cancel proves nothing —
    // the gate opens before the exchange is ever scheduled to notice.
    let lapsAtCancel = transport.laps
    await until("the exchange to run on past the cancel") { transport.laps > lapsAtCancel + 1 }
    #expect(!transport.wasCancelled, "the exchange went down with the caller who started it")

    transport.release()
    #expect(try await staying.value == bought, "the caller who left took the exchange with it")
    #expect(transport.requests.count == 1, "the one left behind had to buy its own after all")
}

// A shared exchange must not become a shared failure that outlives it. Whoever
// comes next is entitled to a fresh attempt rather than to somebody else's
// outage — the same rule as the first fill of the index.
@Test("An exchange that failed is not inherited by the next caller")
func aFailedExchangeIsNotRemembered() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let bought = token(expiringAt: 4_102_444_800)
    let transport = ScriptedTransport([.init(status: 503), .init(body: bought)])
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    await #expect(throws: CloudError.self) { _ = try await tokens.userToken() }
    #expect(try await tokens.userToken() == bought, "the next caller inherited a dead exchange")
    #expect(transport.requests.count == 2)
}

// Foundation's own defect: a pong handler called twice on a connection the
// network aborted. The second call must not reach the continuation.
@Test("A ping answered twice resumes the wait once and drops the second answer")
func aPingAnsweredTwiceResumesOnce() async {
    let probe = TwiceAnsweringPing()
    let coming = Task { try await awaitPong(from: probe) }
    await until("the ping to go out") { probe.isPinging }

    let abort = POSIXError(.ECONNABORTED)
    probe.answerTwice(abort)

    await #expect(throws: POSIXError.self) { try await coming.value }
}

// MARK: - Doubles

/// A ping whose answer arrives twice — what `URLSessionWebSocketTask` did on
/// a connection the network aborted, whatever its contract says.
final class TwiceAnsweringPing: HandshakePinging {
    private let answer = Mutex<(@Sendable ((any Error)?) -> Void)?>(nil)

    var isPinging: Bool { answer.withLock { $0 != nil } }

    func sendPing(_ answer: @escaping @Sendable ((any Error)?) -> Void) {
        self.answer.withLock { $0 = answer }
    }

    func cancel() {}

    func answerTwice(_ error: any Error) {
        guard let answer = answer.withLock({ $0 }) else { return }
        answer(error)
        answer(error)
    }
}

/// A ping the test answers by hand, and a `cancel` that behaves the way
/// `URLSessionWebSocketTask`'s does: it fails the ping in flight through that
/// ping's own answer — once, whichever of the two got there first.
final class ScriptedPing: HandshakePinging {
    private struct State {
        var answer: (@Sendable ((any Error)?) -> Void)?
        var settled = false
        var pinged = false
        var cancelled = false
        var cancels = 0
    }

    private let state = Mutex(State())

    /// Whether the wait has got as far as sending its ping.
    var isPinging: Bool { state.withLock { $0.pinged } }
    /// How many times the wait asked for the socket to be taken down.
    var cancels: Int { state.withLock { $0.cancels } }

    func sendPing(_ answer: @escaping @Sendable ((any Error)?) -> Void) {
        // A ping sent to a task that is already down fails at once rather than
        // parking — the case where the wait was cancelled before it began.
        let failNow = state.withLock { state -> Bool in
            state.pinged = true
            guard !state.cancelled else { return true }
            state.answer = answer
            return false
        }
        if failNow { answer(URLError(.cancelled)) }
    }

    func cancel() {
        state.withLock { state in
            state.cancels += 1
            state.cancelled = true
        }
        answer(URLError(.cancelled))
    }

    /// Answer the ping in flight. Called outside the lock: the answer resumes a
    /// continuation, and a resume is not something to hold a mutex across.
    func answer(_ error: (any Error)?) {
        let waiting = state.withLock { state -> (@Sendable ((any Error)?) -> Void)? in
            guard !state.settled else { return nil }
            state.settled = true
            defer { state.answer = nil }
            return state.answer
        }
        waiting?(error)
    }
}

/// A transport that holds its one answer until the test lets it go, so that
/// several callers are provably inside the exchange together rather than tidily
/// one after another.
///
/// It honours cancellation, as `URLSession` does. That is what makes "the
/// exchange survives the caller who started it" a thing a test can tell apart
/// from its opposite: made a child of that caller, the exchange would be
/// cancelled here and answer nobody.
final class GatedTransport: HTTPTransporting {
    private let body: String
    private let open = Mutex(false)
    private let recorded = Mutex<[URLRequest]>([])
    private let rounds = Mutex(0)
    private let cancelled = Mutex(false)

    init(body: String) {
        self.body = body
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }
    /// How often the held request has looked at the gate. A test that needs to
    /// know a request is *still there* has nothing else to count: absence
    /// cannot be waited for, only outlived.
    var laps: Int { rounds.withLock { $0 } }
    /// Whether the held request was taken down rather than let go.
    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func release() { open.withLock { $0 = true } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        while !open.withLock({ $0 }) {
            if Task.isCancelled {
                cancelled.withLock { $0 = true }
                throw CancellationError()
            }
            rounds.withLock { $0 += 1 }
            await Task.yield()
        }
        let response = HTTPURLResponse.fake(for: request)
        return (Data(body.utf8), response)
    }
}

/// `InMemorySecrets` with a tally of what was read.
///
/// Looking in the store is the last thing a caller does before it either joins the
/// exchange under way or starts one, and from outside the actor it is the only
/// sign that it has got that far.
final class CountingSecrets: CloudSecretStoring {
    private let storage = Mutex<[CloudSecret: String]>([:])
    private let counts = Mutex<[CloudSecret: Int]>([:])

    func reads(_ which: CloudSecret) -> Int { counts.withLock { $0[which] ?? 0 } }

    func secret(_ which: CloudSecret) throws -> String? {
        counts.withLock { $0[which, default: 0] += 1 }
        return storage.withLock { $0[which] }
    }

    func save(_ value: String, as which: CloudSecret) throws {
        storage.withLock { $0[which] = value }
    }

    func forget(_ which: CloudSecret) throws {
        storage.withLock { $0[which] = nil }
    }
}

/// A socket factory answering from a prepared script.
///
/// Once the script runs out it parks rather than answering, so the reconnect
/// loop stops spinning and the test can close it down in its own time.
final class ScriptedSockets: WebSocketConnecting {
    private let outcomes: Mutex<[Result<[NotificationFrame], any Error>]>
    private let count = Mutex(0)
    private let handedOut = Mutex<[FrameQueue]>([])
    /// Which attempts hand out a socket whose keepalive is not answered,
    /// numbered from one. A dead connection is not a refused one: the
    /// handshake succeeds and the reading parks, which is precisely why only a
    /// ping can find it.
    private let deafToPings: Set<Int>

    init(_ outcomes: [Result<[NotificationFrame], any Error>], failingPingOn deaf: Set<Int> = []) {
        self.outcomes = Mutex(outcomes)
        deafToPings = deaf
    }

    var attempts: Int { count.withLock { $0 } }

    /// The sockets this factory has given out, in the order it gave them.
    var sockets: [FrameQueue] { handedOut.withLock { $0 } }

    func connect(to request: URLRequest) async throws -> any WebSocketReceiving {
        let mine = count.withLock { held -> Int in
            held += 1
            return held
        }
        let next = outcomes.withLock { queue in
            queue.isEmpty ? nil : queue.removeFirst()
        }
        guard let next else {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        switch next {
        case .failure(let error): throw error
        case .success(let frames):
            let socket = FrameQueue(frames, pingFails: deafToPings.contains(mine))
            handedOut.withLock { $0.append(socket) }
            return socket
        }
    }
}

/// A socket handing over prepared frames and then holding the line.
///
/// It parks rather than dropping once the frames run out: a drop would send
/// the stream round the reconnect loop again, and a test counting attempts
/// would then be counting how fast it got to its assertions.
final class FrameQueue: WebSocketReceiving {
    private let frames: Mutex<[NotificationFrame]>
    private let closed = Mutex(false)
    private let pings = Mutex(0)
    private let pingFails: Bool

    init(_ frames: [NotificationFrame], pingFails: Bool = false) {
        self.frames = Mutex(frames)
        self.pingFails = pingFails
    }

    /// Whether anybody closed it. Which run closes which socket is the whole
    /// question once `stop()` and `start()` follow each other closely.
    var isClosed: Bool { closed.withLock { $0 } }

    /// How many keepalives it was asked for. The channel is silent by design,
    /// so this is the only sign the socket is being kept alive at all.
    var pingCount: Int { pings.withLock { $0 } }

    /// Whether every prepared frame has been handed over. What a test waits for
    /// when it expects the frames to lead to nothing: there is no wake to
    /// watch for, only the delivery after which nothing more can arrive.
    var isDrained: Bool { frames.withLock { $0.isEmpty } }

    func ping() async throws {
        pings.withLock { $0 += 1 }
        if pingFails { throw URLError(.networkConnectionLost) }
    }

    func receive() async throws -> NotificationFrame {
        let next = frames.withLock { queue in
            queue.isEmpty ? nil : queue.removeFirst()
        }
        if let next { return next }
        // Parked until somebody closes it, and then failed — which is what the
        // real socket does and the whole reason the stream ever calls `cancel`
        // on one: `URLSessionWebSocketTask.receive()` is no cancellation point,
        // so closing the socket is the only thing that ends a read in flight.
        // Parking for an hour instead meant a keepalive could take the socket
        // down and the reader would go on waiting, which is the failure this
        // double existed to rule out.
        while !isClosed {
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.cancelled)
    }

    func cancel() {
        closed.withLock { $0 = true }
    }
}

/// A handshake that parks until the test lets it go.
///
/// Deaf to cancellation on purpose. `URLSessionWebSocketTask` does not come
/// back early because the task that asked for it gave up — that is the whole
/// premise of the stop being made to wait — so a double that threw
/// `CancellationError` here would be testing a world we do not live in. It
/// waits on a flag, and the waiting is spelled with `Task.yield` rather than
/// `Task.sleep` because sleeping is a cancellation point and this must have
/// none.
///
/// The cancellation handler is bookkeeping and nothing else: it lets a test
/// release the gate *after* the cancel has landed instead of racing it.
final class ParkingSockets: WebSocketConnecting {
    private let started = Mutex(0)
    private let released = Mutex(Set<Int>())
    private let cancels = Mutex(0)
    private let handedOut = Mutex<[FrameQueue]>([])

    /// The sockets this factory has given out, in the order it gave them.
    var sockets: [FrameQueue] { handedOut.withLock { $0 } }

    func connect(to request: URLRequest) async throws -> any WebSocketReceiving {
        let mine = started.withLock { count in
            count += 1
            return count
        }
        await withTaskCancellationHandler {
            while !released.withLock({ $0.contains(mine) }) {
                await Task.yield()
            }
        } onCancel: {
            cancels.withLock { $0 += 1 }
        }
        let socket = FrameQueue([])
        handedOut.withLock { $0.append(socket) }
        return socket
    }

    /// Wait until the nth handshake has begun.
    func untilStarted(_ n: Int) async {
        await until("handshake \(n) to start") { self.started.withLock { $0 } >= n }
    }

    /// Wait until n cancels have reached parked handshakes.
    func untilCancelled(_ n: Int) async {
        await until("\(n) cancelled handshake(s)") { self.cancels.withLock { $0 } >= n }
    }

    /// Let the nth handshake finish.
    func release(_ n: Int) {
        released.withLock { _ = $0.insert(n) }
    }
}

/// A server that answers nothing at all, so that the only way out of a request
/// is the caller giving up.
///
/// A `URLProtocol` rather than one more `HTTPTransporting` double: what is
/// under test is `URLSessionTransport` itself — the catch that reads what
/// `URLSession` threw — and a double standing in for the transport would step
/// over exactly that line. Requests are held by URL rather than counted,
/// because the tests here run side by side and each has to wait for its own.
final class SilentServer: URLProtocol {
    private static let held = Mutex<Set<String>>([])

    /// A URL no other test in this file is waiting on.
    static func url() -> URL {
        URL.constant("https://sync.invalid/sync/v3/files/\(UUID().uuidString)")
    }

    /// Whether a request for this URL is sitting inside the handler.
    static func isParked(_ url: URL) -> Bool {
        held.withLock { $0.contains(url.absoluteString) }
    }

    /// A session that goes nowhere but here.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentServer.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Nothing is answered, and nothing is failed: the request stays here until
    /// somebody takes it away.
    override func startLoading() {
        guard let url = request.url?.absoluteString else { return }
        Self.held.withLock { _ = $0.insert(url) }
    }

    /// Which, on this handler, only ever happens because the task was
    /// cancelled.
    override func stopLoading() {
        guard let url = request.url?.absoluteString else { return }
        Self.held.withLock { _ = $0.remove(url) }
    }
}

/// A transport that expects to be reached by nothing, and remembers it if it
/// is.
///
/// The assertion it serves is an absence — that a document whose caller has
/// gone never goes out — and an absence needs somebody to have been watching
/// for it.
final class UnusedTransport: HTTPTransporting {
    private let reached = Mutex<[String]>([])

    /// Every call that arrived, in order.
    var visits: [String] { reached.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        reached.withLock { $0.append("send \(request.url?.path() ?? "")") }
        throw CloudError.malformedResponse("the test expected no request at all")
    }

    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        onProgress: @escaping TransferProgress
    ) async throws -> (Data, HTTPURLResponse) {
        reached.withLock { $0.append("upload \(request.url?.path() ?? "")") }
        throw CloudError.malformedResponse("the test expected no upload")
    }
}

/// A transport whose downloads land in a directory the test owns, so that what
/// the client leaves behind can be counted without the shared temporary
/// directory getting in the way.
final class DownloadingTransport: HTTPTransporting {
    private let directory: URL
    private let body: Data

    init(directory: URL, body: Data) {
        self.directory = directory
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Nothing on this path should need one: the token is in the store.
        throw CloudError.malformedResponse("the test expected no plain request")
    }

    func download(
        _ request: URLRequest,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        let file = directory.appending(path: UUID().uuidString)
        try body.write(to: file)
        onProgress(Int64(body.count), Int64(body.count))
        let response = HTTPURLResponse.fake(for: request)
        return (file, response)
    }
}
