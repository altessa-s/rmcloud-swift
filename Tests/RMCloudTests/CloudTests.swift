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

// MARK: - The account plan from the token claims

@Test("The plan and the sync scope are read from the token claims")
func readsPlanFromToken() throws {
    // The shape matches a live reply: scopes on one line, space separated.
    let token = syntheticToken(claims: #"{"level":"connect","scopes":"mail:-1 docedit sync:tortoise intgr"}"#)
    let plan = try #require(TokenProvider.plan(fromUserToken: token))

    #expect(plan.level == "connect")
    #expect(plan.syncScope == "sync:tortoise")
    #expect(plan.isConnect)
}

@Test("An unknown level is kept as is and claims nothing about a subscription")
func keepsUnknownLevel() throws {
    // Only "connect" has been seen live. An unfamiliar word can neither be
    // passed off as a subscription nor declared its absence — it is just kept.
    let plan = try #require(TokenProvider.plan(fromUserToken: syntheticToken(claims: #"{"level":"basic"}"#)))

    #expect(plan.level == "basic")
    #expect(!plan.isConnect)
    #expect(plan.syncScope == nil)
}

// An account without Connect does not name another plan — the claim is absent.
// On a second live account: 11 claims against 13, no
// `level`, and `sync:fox` where the subscriber has `sync:tortoise`.
@Test("A token with no level is an account without Connect, not a silence")
func readsAnAccountWithoutConnect() throws {
    let plan = try #require(
        TokenProvider.plan(fromUserToken: syntheticToken(claims: #"{"scopes":"screenshare sync:fox"}"#))
    )

    #expect(plan.level == nil)
    #expect(!plan.isConnect)
    // The scope survives; throwing it away with the plan would leave the
    // account readable but unable to say which generation of
    // sync it belonged to.
    #expect(plan.syncScope == "sync:fox")

    // An empty level is no level either.
    #expect(TokenProvider.plan(fromUserToken: syntheticToken(claims: #"{"level":""}"#))?.level == nil)
}

@Test("A token we cannot read at all is still a silence")
func staysSilentOnAnUnreadableToken() {
    // These say nothing about the account, and answering "no subscription" on
    // the strength of them would be asserting the unverified.
    #expect(TokenProvider.plan(fromUserToken: "not-a-jwt") == nil)
    #expect(TokenProvider.plan(fromUserToken: syntheticToken(claims: "not json")) == nil)
}

@Test("A stored user token is used instead of buying another one")
func reusesTheStoredUserToken() async throws {
    // The reason the token is kept at all: a process that starts with one in
    // the store must not go and ask for a second. `rmctl` is started once per
    // page of a notebook, and the server refuses the twenty-third exchange.
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let alive = syntheticToken(claims: #"{"exp": 4102444800}"#)          // 2100
    try secrets.save(alive, as: .userToken)

    let transport = ScriptedTransport([])
    let tokens = TokenProvider(transport: transport, secrets: secrets)
    #expect(try await tokens.userToken() == alive)
    #expect(transport.requests.isEmpty, "a stored token still cost a request")
}

@Test("An expired token is replaced, and the fresh one is kept")
func replacesAnExpiredToken() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    try secrets.save(syntheticToken(claims: #"{"exp": 1000}"#), as: .userToken)   // 1970

    let fresh = syntheticToken(claims: #"{"exp": 4102444800}"#)
    let transport = ScriptedTransport([.init(body: fresh)])
    let tokens = TokenProvider(transport: transport, secrets: secrets)
    #expect(try await tokens.userToken() == fresh)
    #expect(try secrets.secret(.userToken) == fresh, "the new token was not kept")
}

@Test("A token that does not say when it dies is not kept at all")
func doesNotKeepATokenWithoutAnExpiry() async throws {
    // Trusting such a token would mean remembering its age ourselves, and a
    // stale one handed to a later process is a 401 nobody can explain.
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let transport = ScriptedTransport([.init(body: "not-a-jwt")])
    let tokens = TokenProvider(transport: transport, secrets: secrets)
    #expect(try await tokens.userToken() == "not-a-jwt")
    #expect(try secrets.secret(.userToken) == nil)
}

@Test("Revoking posts the device token to device/delete and leaves the Keychain alone")
func revokingTellsTheServerAndKeepsTheToken() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let transport = ScriptedTransport([.init(status: 200)])
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    try await tokens.revokeDevice()

    let request = try #require(transport.requests.first)
    #expect(request.url?.path == "/token/json/3/device/delete")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device")
    // Revoking and forgetting are two steps, reported apart: the token goes
    // in `forgetDevice`, whatever the server said here.
    #expect(try secrets.secret(.deviceToken) == "device")
}

@Test("A device the server no longer knows counts as revoked")
func revokingARefusedTokenIsNotAFailure() async throws {
    // What the caller asked for is true whichever side made it so; a refusal
    // here would make a disconnect fail over a token that is already dead.
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let tokens = TokenProvider(transport: ScriptedTransport([.init(status: 401)]), secrets: secrets)
    try await tokens.revokeDevice()

    // A server that cannot be reached is a different answer, and it is heard —
    // once the policy has had its attempts. The script runs out after the
    // first 503 and the double answers 500 from then on.
    let sleeper = RecordingSleeper()
    let failing = TokenProvider(
        transport: ScriptedTransport([.init(status: 503)]), secrets: secrets, sleeper: sleeper
    )
    await #expect(throws: CloudError.self) { try await failing.revokeDevice() }
    #expect(sleeper.delays.count == RetryPolicy.default.maxAttempts - 1, "a 5xx on the auth host was not retried")
}

@Test("With no device token there is nothing to revoke and nobody is asked")
func revokingWithoutATokenMakesNoRequest() async throws {
    let transport = ScriptedTransport([])
    let tokens = TokenProvider(transport: transport, secrets: InMemorySecrets())
    try await tokens.revokeDevice()
    #expect(transport.requests.isEmpty)
}

@Test("Forgetting the device forgets the user token with it")
func forgettingClearsBoth() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    try secrets.save(syntheticToken(claims: #"{"exp": 4102444800}"#), as: .userToken)
    let tokens = TokenProvider(transport: ScriptedTransport([]), secrets: secrets)
    try await tokens.forgetDevice()
    #expect(try secrets.secret(.userToken) == nil)
}

// MARK: - Tokens that arrive after the account is gone

// An actor serialises its statements and lets go of its turn at every await.
// Both exchanges below suspend on a request, and disconnecting is free to run
// in that gap — so without a check, the answer could come back and write a working credential
// into a Keychain group the app, the extension and `rmctl` all read, for an
// account the user had just been promised was forgotten.

@Test("A user token that arrives after the device was forgotten is not kept")
func lateUserTokenIsDropped() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let transport = HeldTransport(body: syntheticToken(claims: #"{"exp": 4102444800}"#))
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    let fetching = Task { try await tokens.userToken() }
    await transport.waitForRequest()
    try await tokens.forgetDevice()
    await transport.letThrough()

    var refused = false
    do { _ = try await fetching.value } catch { refused = true }
    // Refused rather than returned: the caller asked whether it may speak for
    // this account, and by the time the answer came the account was gone.
    #expect(refused)
    #expect(try secrets.secret(.userToken) == nil)
}

@Test("A device token that arrives after the device was forgotten is not written")
func lateDeviceTokenIsDropped() async throws {
    // The worse half of the pair: a device token is the long-lived one, and it
    // does not expire itself out of the way.
    let secrets = InMemorySecrets()
    let transport = HeldTransport(body: "device-token")
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    let registering = Task { try await tokens.registerDevice(oneTimeCode: "abcdefgh") }
    await transport.waitForRequest()
    try await tokens.forgetDevice()
    await transport.letThrough()

    var refused = false
    do { try await registering.value } catch { refused = true }
    #expect(refused)
    #expect(try secrets.secret(.deviceToken) == nil)
    #expect(try secrets.secret(.deviceID) == nil)
}

// MARK: - Doubles

/// A transport that holds its answer until the test lets it through.
///
/// The point is to stand the test *inside* the suspension: once the request has
/// arrived, the actor under test has given up its turn, and whatever the test
/// does next runs before the answer lands.
/// `registrationSession` guards one process; the Keychain is shared with
/// the app, and disconnecting there empties it mid-exchange. The bought
/// token must not be written back for the erased account.
@Test("A user token that lands after the account left the Keychain is dropped")
func crossProcessDisconnectDropsTheBoughtToken() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = HeldTransport(body: liveToken())
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    let buying = Task { try await tokens.userToken() }
    await transport.waitForRequest()
    try secrets.forget(.deviceToken)
    await transport.letThrough()

    await #expect(throws: CloudError.notRegistered) { _ = try await buying.value }
    #expect(try secrets.secret(.userToken) == nil)
}

private final class HeldTransport: HTTPTransporting {
    private let body: String
    private let gate = Gate()

    init(body: String) {
        self.body = body
    }

    /// Wait until the request is in flight.
    func waitForRequest() async { await gate.waitForArrival() }

    /// Let the answer through.
    func letThrough() async { await gate.open() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await gate.stopHere()
        let response = HTTPURLResponse.fake(for: request)
        return (Data(body.utf8), response)
    }
}

/// A transport that answers from a prepared script and records the requests.
final class ScriptedTransport: HTTPTransporting {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = ""
        var headers: [String: String] = [:]
    }

    private let replies: Mutex<[Reply]>
    private let recorded = Mutex<[URLRequest]>([])

    init(_ replies: [Reply]) {
        self.replies = Mutex(replies)
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let reply = replies.withLock { queue -> Reply in
            queue.isEmpty ? Reply(status: 500) : queue.removeFirst()
        }
        let response = HTTPURLResponse.fake(reply.status, for: request, headers: reply.headers)
        return (Data(reply.body.utf8), response)
    }
}

// An account with no tablet on it cannot exchange its device token for a user
// token: the call answers 400 before a tablet is paired
// and goes through with the very same token afterwards. Read as a plain 400 it
// reads as "server error, try later" — advice that would never come true.
@Test("A 400 from the token exchange means the account has no tablet, and is not asked again")
func readsAnAccountWithoutATablet() async throws {
    let transport = ScriptedTransport([.init(status: 400, body: "")])
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: CloudSecret.deviceToken)
    let sleeper = RecordingSleeper()
    let tokens = TokenProvider(transport: transport, secrets: secrets, sleeper: sleeper)

    await #expect(throws: CloudError.accountWithoutTablet) {
        _ = try await tokens.userToken()
    }
    #expect(RetryPolicy.default.shouldRetry(.accountWithoutTablet) == false)
    // The exchange goes through the same retry as every other request now, and
    // a 400 must stay what it was: one request, no pause, no second one. A
    // tablet does not get paired because the question was asked twice.
    #expect(transport.requests.count == 1, "a 400 on the exchange was repeated")
    #expect(sleeper.delays.isEmpty)
}

// The exchange used to go out once, bare, while every protocol request went
// through the retry. The user token is bought on a schedule, in the middle of
// whatever the client was doing, so one 503 on the auth host failed a request
// that would have survived the same 503 on the sync host.
@Test("A user token exchange that meets a 503 is tried again, like any other request")
func retriesTheUserTokenExchange() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let fresh = syntheticToken(claims: #"{"exp": 4102444800}"#)
    let transport = ScriptedTransport([
        .init(status: 503),
        .init(body: fresh),
    ])
    let sleeper = RecordingSleeper()
    let tokens = TokenProvider(transport: transport, secrets: secrets, sleeper: sleeper)

    #expect(try await tokens.userToken() == fresh)
    #expect(transport.requests.count == 2, "the 503 was taken as final")
    #expect(sleeper.delays.count == 1, "one pause between two attempts")
    #expect(try secrets.secret(.userToken) == fresh, "the token bought on the second try was not kept")
}

// MARK: - How an index is addressed

/// A client whose only reply is one index blob, and a root that points at the
/// hash the caller names.
private func clientServing(index text: String) -> (CloudClient, ScriptedTransport) {
    let transport = ScriptedTransport([
        .init(body: "user-token"),                       // the token exchange
        .init(body: text),                               // the index blob
    ])
    let secrets = InMemorySecrets()
    try? secrets.save("device-token", as: CloudSecret.deviceToken)
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )
    return (client, transport)
}

// Two live accounts address their indexes by two different hashes: the older
// one by the hash of the index file, the newer by the node hash — the SHA-256
// over the children's hashes. Requiring the file hash made every account of the
// newer generation unreadable, and the user was told the protocol had changed.
@Test("An index vouched for by its file hash is read")
func readsIndexByFileHash() async throws {
    let text = "3\naaaa:0:doc-1:0:10\n"
    let (client, _) = clientServing(index: text)

    let index = try await client.index(
        hash: ContentHash.blob(Data(text.utf8)),
        name: CloudClient.rootIndexName
    )
    #expect(index.entries.count == 1)
}

@Test("An index vouched for by its node hash is read too")
func readsIndexByNodeHash() async throws {
    // The bytes hash to one thing and the root points at another — the case a
    // live account of the current generation answers with.
    let text = "3\naaaa:80000000:doc-1:1:210\n"
    let entries = try IndexParser.parse(text).entries
    let nodeHash = try ContentHash.node(of: entries)
    #expect(nodeHash != ContentHash.blob(Data(text.utf8)), "the two hashes must differ here")

    let (client, _) = clientServing(index: text)
    let index = try await client.index(hash: nodeHash, name: CloudClient.rootIndexName)
    #expect(index.entries.count == 1)
}

@Test("An index vouched for by neither hash is refused")
func refusesIndexThatMatchesNeitherHash() async throws {
    let (client, _) = clientServing(index: "3\naaaa:0:doc-1:0:10\n")

    // Accepting either hash must not turn into accepting anything: substituted
    // bytes match neither, because both are computed from the bytes in hand.
    await #expect(throws: CloudError.self) {
        try await client.index(hash: String(repeating: "f", count: 64), name: "root.docSchema")
    }
}

// MARK: - Index format

@Test("A schema 3 index parses")
func parsesSchemaV3() throws {
    let text = """
    3
    aaaa:80000000:doc-1:2:120
    bbbb:80000000:doc-2:1:40
    """
    let index = try IndexParser.parse(text)

    #expect(index.schema == .v3)
    #expect(index.entries.count == 2)
    #expect(index.entries[0].documentID == "doc-1")
    #expect(index.entries[0].subfiles == 2)
    #expect(index.entries[1].size == 40)
    #expect(index.entries[0].isDocument)
}

@Test("In schema 4 the second line is a header, not an entry")
func parsesSchemaV4Header() throws {
    let text = """
    4
    0:.:2:160
    aaaa:80000000:doc-1:2:120
    bbbb:80000000:doc-2:1:40
    """
    let index = try IndexParser.parse(text)

    #expect(index.schema == .v4)
    #expect(index.entries.count == 2)
    #expect(index.entries.map(\.documentID) == ["doc-1", "doc-2"])
}

// `.whitespaces` does not include `\r`, so an index whose lines ended in
// `\r\n` kept the `\r` on every line and its header read as an unknown
// schema `4\r`. The whole index was refused over a line ending.
@Test("An index with CRLF line endings parses the same as one with LF")
func parsesCRLFIndex() throws {
    let lines = ["4", "0:.:2:160", "aaaa:80000000:doc-1:2:120", "bbbb:80000000:doc-2:1:40"]
    let unix = try IndexParser.parse(lines.joined(separator: "\n"))
    let windows = try IndexParser.parse(lines.joined(separator: "\r\n") + "\r\n")

    #expect(windows == unix)
    #expect(windows.schema == .v4)
    #expect(windows.entries.map(\.documentID) == ["doc-1", "doc-2"])
}

@Test("A v4 header count mismatch does not lose the library")
func toleratesCountMismatch() throws {
    let text = """
    4
    0:.:99:160
    aaaa:80000000:doc-1:2:120
    """
    #expect(try IndexParser.parse(text).entries.count == 1)
}

@Test("An unknown schema gives a clear error, not a crash")
func rejectsUnknownSchema() {
    #expect(throws: CloudError.unsupportedSchema("7")) {
        try IndexParser.parse("7\naaaa:0:doc:0:1")
    }
}

@Test("A line without five fields is rejected")
func rejectsShortLine() {
    #expect(throws: CloudError.self) {
        try IndexParser.parse("3\naaaa:0:doc:0")
    }
}

@Test("Serialisation always emits v4 and parses back")
func serializesAsV4() throws {
    let entries = [
        IndexEntry(hash: "aa", type: IndexEntry.fileType, documentID: "doc.metadata", subfiles: 0, size: 10),
        IndexEntry(hash: "bb", type: IndexEntry.fileType, documentID: "doc.pdf", subfiles: 0, size: 90),
    ]
    let text = IndexParser.serializeRoot(entries)
    let parsed = try IndexParser.parse(text)

    #expect(text.hasPrefix("4\n0:.:2:100\n"))
    #expect(parsed.entries == entries)
}

@Test("A document file is found by extension")
func findsEntryByExtension() throws {
    let index = try IndexParser.parse("""
    3
    aa:0:doc.metadata:0:10
    bb:0:doc.pdf:0:90
    """)
    #expect(index.entry(withExtension: "pdf")?.hash == "bb")
    #expect(index.entry(withExtension: "epub") == nil)
}

// MARK: - Hashes

@Test("A node hash does not depend on child order")
func nodeHashIsOrderIndependent() throws {
    let a = IndexEntry(hash: "00ff", type: "0", documentID: "a", subfiles: 0, size: 1)
    let b = IndexEntry(hash: "ff00", type: "0", documentID: "b", subfiles: 0, size: 1)

    #expect(try ContentHash.node(of: [a, b]) == ContentHash.node(of: [b, a]))
}

@Test("A node hash tracks its children")
func nodeHashTracksChildren() throws {
    let a = IndexEntry(hash: "00ff", type: "0", documentID: "a", subfiles: 0, size: 1)
    let changed = IndexEntry(hash: "00fe", type: "0", documentID: "a", subfiles: 0, size: 1)

    #expect(try ContentHash.node(of: [a]) != ContentHash.node(of: [changed]))
}

@Test("A node hash requires hex")
func nodeHashRejectsNonHex() {
    let bad = IndexEntry(hash: "zz", type: "0", documentID: "a", subfiles: 0, size: 1)
    #expect(throws: CloudError.self) {
        try ContentHash.node(of: [bad])
    }
}

// MARK: - Tokens

@Test("Registration stores the device token")
func registrationStoresDeviceToken() async throws {
    let secrets = InMemorySecrets()
    let transport = ScriptedTransport([.init(body: "device-token-value")])
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    try await tokens.registerDevice(oneTimeCode: "abcdefgh")

    #expect(try secrets.secret(.deviceToken) == "device-token-value")
    #expect(try secrets.secret(.deviceID) != nil)
    #expect(transport.requests.first?.httpMethod == "POST")
}

// The server takes the label from a set of its own, and an arbitrary string is
// refused. Asserted on the bytes that go out rather than on the constant,
// because what matters is what the request carries: the same label comes back
// in the user token as `device-desc`, and a live account has confirmed this
// one.
@Test("Registration calls this client a Mac desktop, and says so on the wire")
func registrationSendsTheMacLabel() async throws {
    let transport = ScriptedTransport([.init(body: "device-token-value")])
    let tokens = TokenProvider(transport: transport, secrets: InMemorySecrets())

    try await tokens.registerDevice(oneTimeCode: "abcdefgh")

    let body = try #require(transport.requests.first?.httpBody)
    let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(sent["deviceDesc"] == "desktop-macos")
    #expect(sent["code"] == "abcdefgh")
    // A fresh identifier per registration, lower case as the protocol's own
    // identifiers are.
    let deviceID = try #require(sent["deviceID"])
    #expect(UUID(uuidString: deviceID) != nil)
    #expect(deviceID == deviceID.lowercased())
}

// The service reads this header, and it turns some values away outright — a
// browser's `Mozilla/5.0` does not get an answer. What it accepts is the
// desktop's own shape, so that is what goes out: the left-hand version names
// the protocol generation being spoken, the right-hand one the system actually
// running.
@Test("Requests name this client the way the desktop names itself")
func requestsCarryTheDesktopUserAgent() async throws {
    let scheme = /desktop\/[0-9.]+ \(macos [0-9]+\.[0-9]+(\.[0-9]+)?\)/
    #expect(ProtocolRequest.userAgent.wholeMatch(of: scheme) != nil)

    // And it is on the wire, not merely spelled in a constant.
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    try secrets.save(syntheticToken(claims: #"{"exp": 4102444800}"#), as: .userToken)
    let transport = ScriptedTransport([.init(body: "blob")])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    _ = try await client.blob(hash: "abc", name: "abc.metadata", verify: false)
    #expect(
        transport.requests.first?.value(forHTTPHeaderField: "user-agent")
            == ProtocolRequest.userAgent
    )

    // The auth host too. It is a different host and a different contour, and
    // the header is not required there — but a client that names itself on one
    // host and stays anonymous on the other is two clients to anybody reading
    // the logs, ours or theirs.
    let exchanging = ScriptedTransport([.init(body: "device-token")])
    let fresh = TokenProvider(transport: exchanging, secrets: InMemorySecrets())
    try await fresh.registerDevice(oneTimeCode: "abcdefgh")
    #expect(
        exchanging.requests.first?.value(forHTTPHeaderField: "user-agent")
            == ProtocolRequest.userAgent
    )
}

@Test("A code that is not eight characters never reaches the network")
func rejectsShortOneTimeCode() async {
    let transport = ScriptedTransport([])
    let tokens = TokenProvider(transport: transport, secrets: InMemorySecrets())

    await #expect(throws: CloudError.invalidOneTimeCode) {
        try await tokens.registerDevice(oneTimeCode: "abc")
    }
    #expect(transport.requests.isEmpty)
}

@Test("A 401 during registration reads as a wrong code")
func mapsUnauthorizedToBadCode() async {
    let transport = ScriptedTransport([.init(status: 401)])
    let tokens = TokenProvider(transport: transport, secrets: InMemorySecrets())

    await #expect(throws: CloudError.invalidOneTimeCode) {
        try await tokens.registerDevice(oneTimeCode: "abcdefgh")
    }
}

@Test("Without registration no user token is requested")
func requiresRegistration() async {
    let tokens = TokenProvider(transport: ScriptedTransport([]), secrets: InMemorySecrets())

    await #expect(throws: CloudError.notRegistered) {
        _ = try await tokens.userToken()
    }
}

@Test("The user token is cached and refreshed when it expires")
func refreshesUserToken() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([.init(body: "user-1"), .init(body: "user-2")])
    let clock = Mutex(Date(timeIntervalSince1970: 0))
    let tokens = TokenProvider(
        transport: transport,
        secrets: secrets,
        now: { clock.withLock { $0 } }
    )

    #expect(try await tokens.userToken() == "user-1")
    #expect(try await tokens.userToken() == "user-1", "the second call comes from the cache")

    clock.withLock { $0 = Date(timeIntervalSince1970: 21 * 60 * 60) }
    #expect(try await tokens.userToken() == "user-2")
    #expect(transport.requests.count == 2)
}

// MARK: - Client

@Test("The root is read from the v4 path")
func readsRootFromV4() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(body: #"{"hash":"roothash","generation":42}"#),
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    let root = try await client.root()

    #expect(root == CloudRoot(hash: "roothash", generation: 42))
    // v4 first, because that is where the official desktop reads and where the
    // pointer says the whole of what it has to say. Both paths answer 200 with
    // the same body on a live account, so the order is not about finding a
    // working path but about preferring the one the official client prefers.
    #expect(transport.requests.last?.url?.path() == "/sync/v4/root")
    // The pointer is asked for by the name of the operation, not of a file,
    // and the read carries it as well as the write. Both hosts serve the read
    // without it — checked on `internal` and on tectonic both — and that is
    // the reason to send it: an undocumented tolerance is not a promise, the
    // official client sends it here, and a header omitted because nothing has
    // objected yet is one the service may start objecting to.
    #expect(transport.requests.last?.value(forHTTPHeaderField: "rm-filename") == "roothash")
}

@Test("A settled path that starts answering 404 is given up, not reported as no root")
func unsettlesTheRootPathOnA404() async throws {
    let (client, transport) = try clientWithStoredToken([
        .init(body: #"{"hash":"first","generation":1}"#),      // v4 answers
        .init(status: 404),                                      // v4 no longer does
        .init(body: #"{"hash":"second","generation":2}"#),     // v3 still does
    ])

    #expect(try await client.root().hash == "first")
    // Kept, the settled path would have turned this read — and every read to
    // the end of the process — into `noRootYet` on the strength of one 404,
    // while the other path was serving the account all along.
    #expect(try await client.root().hash == "second")

    let reads = transport.requests.compactMap { $0.url?.path() }
    #expect(reads == ["/sync/v4/root", "/sync/v4/root", "/sync/v3/root"])
    #expect(await client.rootVersion == .v3)
}

@Test("If v4 answers 404, the root comes from v3")
func fallsBackToV3Root() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(status: 404),
        .init(body: #"{"hash":"roothash","generation":7}"#),
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    let root = try await client.root()

    #expect(root.generation == 7)
    #expect(transport.requests.last?.url?.path() == "/sync/v3/root")
    // Both attempts, not just the one that answered: the 404 is what settles
    // which path this account keeps its pointer at, and a probe that asked
    // differently from the read would settle it on a different question.
    let reads = transport.requests.filter { $0.url?.path().hasSuffix("/root") == true }
    #expect(reads.count == 2)
    #expect(reads.allSatisfy { $0.value(forHTTPHeaderField: "rm-filename") == "roothash" })
}

@Test("A blob with foreign contents is rejected")
func rejectsBlobWithWrongHash() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(body: "contents that do not match the hash"),
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    await #expect(throws: CloudError.self) {
        _ = try await client.blob(hash: "deadbeef", name: "doc.metadata")
    }
}

@Test("A blob downloaded to a file arrives whole and reports its progress")
func downloadsBlobToFile() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let payload = "the contents of a large original"
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(body: payload),
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    let reports = Mutex<[(completed: Int64, total: Int64)]>([])
    let file = try await client.blobFile(
        hash: ContentHash.blob(Data(payload.utf8)),
        name: "doc.pdf"
    ) { completed, total in
        reports.withLock { $0.append((completed, total)) }
    }
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(try String(contentsOf: file, encoding: .utf8) == payload)
    #expect(reports.withLock { $0.last?.completed } == Int64(payload.utf8.count))
    #expect(transport.requests.last?.value(forHTTPHeaderField: "rm-filename") == "doc.pdf")
}

@Test("A downloaded file with foreign contents is rejected")
func rejectsDownloadedFileWithWrongHash() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(body: "contents that do not match the hash"),
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    await #expect(throws: CloudError.self) {
        _ = try await client.blobFile(hash: "deadbeef", name: "doc.pdf")
    }
}

@Test("A file hash is the blob hash, counted in chunks")
func hashesFileInChunks() throws {
    // More than one read chunk: a short file would not exercise the loop.
    let payload = Data(repeating: 7, count: 9 * 1024 * 1024 + 13)
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "rmcloud-hash-\(UUID().uuidString)")
    try payload.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(try ContentHash.blob(contentsOf: file) == ContentHash.blob(payload))
}

@Test("The client survives 5xx: the retry follows the policy")
func clientRetriesServerError() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let payload = "contents"
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(status: 503),
        .init(body: payload),
    ])
    let sleeper = RecordingSleeper()
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets),
        policy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(10)),
        sleeper: sleeper
    )

    let data = try await client.blob(hash: ContentHash.blob(Data(payload.utf8)), name: "doc.pdf")

    #expect(String(decoding: data, as: UTF8.self) == payload)
    #expect(sleeper.delays.count == 1, "one pause between two attempts")
}

// Writing the root is the one request that must not be repeated blindly: a
// network error may mean it went through with the answer lost on the way back,
// and a second write would point the root at a tree built on a generation that
// has stopped being current. A 429 is the exception — the server says outright
// that it took nothing. On a live account: the root was being polled from
// another process, a write met 429, and the command failed in the user's hands.
@Test("A write refused with 429 waits and goes again")
func rootWriteRepeatsAfterRateLimit() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        // The root is read first, as every writer reads it: the write goes to
        // whichever path this account answers on, and that is settled here.
        .init(body: #"{"hash":"aa","generation":41}"#),
        .init(status: 429, headers: ["Retry-After": "0"]),
        .init(body: #"{"hash":"aa","generation":42}"#),
    ])
    let sleeper = RecordingSleeper()
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets),
        policy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(10)),
        sleeper: sleeper
    )

    _ = try await client.root()
    let generation = try await client.putRoot(hash: "aa", generation: 41)

    #expect(generation == 42)
    #expect(sleeper.delays.count == 1, "one pause between two attempts")
}

// The pointer is read from v4 and written to v3, and the two are allowed to
// disagree: that is what the official client does on an account whose region
// its token names. Following the read here would have meant that every account
// read from v4 — which is now every account — had its pointer written with a
// PUT that has never been seen on the wire, ours or anybody's.
@Test("The root is written to v3 even when it was read from v4")
func rootIsWrittenToV3WhateverTheReadFound() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(body: #"{"hash":"roothash","generation":42}"#),   // the read, on v4
        .init(body: #"{"hash":"newhash","generation":43}"#),    // the write
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    _ = try await client.root()
    #expect(transport.requests.last?.url?.path() == "/sync/v4/root")

    let generation = try await client.putRoot(hash: "newhash", generation: 42)

    #expect(generation == 43)
    let write = try #require(transport.requests.last)
    #expect(write.httpMethod == "PUT")
    #expect(write.url?.path() == "/sync/v3/root")
    #expect(write.value(forHTTPHeaderField: "rm-filename") == "roothash")
    #expect(write.value(forHTTPHeaderField: "content-type") == "application/json")
}

// And it needs no read of its own to know where to go: the path is a constant,
// so a writer that has its generation from elsewhere is not refused for a
// reason that has stopped existing.
@Test("A write does not need the root to have been read first")
func rootWriteNeedsNoPriorRead() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(body: #"{"hash":"newhash","generation":9}"#),
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    #expect(try await client.putRoot(hash: "newhash", generation: 8) == 9)
    #expect(transport.requests.last?.url?.path() == "/sync/v3/root")
}

// A 503 is retried on reads — it is in the policy — and deliberately is not on
// the root write: unlike a 429 it does not say the request was refused, so it
// may have been applied with the answer lost on the way back.
@Test("A write that met a 503 is not repeated: it may have gone through")
func rootWriteDoesNotRepeatAfterServerError() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(body: #"{"hash":"aa","generation":41}"#),
        .init(status: 503),
        .init(body: #"{"hash":"aa","generation":42}"#),
    ])
    let sleeper = RecordingSleeper()
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets),
        policy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(10)),
        sleeper: sleeper
    )

    _ = try await client.root()
    // The refusal named, not merely its type: `CloudError.self` also matches
    // the client declining to write a root it has never read, and that would
    // have passed this test without a single write being attempted.
    await #expect(throws: CloudError.writeRejected(status: 503, detail: "roothash — (empty body)")) {
        _ = try await client.putRoot(hash: "aa", generation: 41)
    }
    #expect(sleeper.delays.isEmpty, "no waiting, no second write")
}

// An item the cloud has never heard of — a file kept on this Mac — has no
// hash, and a request built from it collapses to `sync/v3/files/`. The server
// answers 404, which reads as "no such document" and sent one live
// investigation down the wrong path: the mirror was failing every pass over a
// `.zip` the tablet would not take. Refused before the wire, by name.
@Test("A request without a hash never leaves the client")
func blobWithoutHashIsRefusedBeforeTheWire() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    await #expect(throws: CloudError.missingHash(name: "notes.zip")) {
        _ = try await client.blob(hash: "", name: "notes.zip")
    }
    await #expect(throws: CloudError.missingHash(name: "notes.zip")) {
        _ = try await client.blobFile(hash: "", name: "notes.zip")
    }
    #expect(transport.requests.isEmpty, "not even a token was fetched")
}

@Test("A 400 is not retried: another request will not fix it")
func clientDoesNotRetryBadRequest() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let transport = ScriptedTransport([
        .init(body: "user-token"),
        .init(status: 400),
    ])
    let sleeper = RecordingSleeper()
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets),
        sleeper: sleeper
    )

    await #expect(throws: CloudError.self) {
        _ = try await client.blob(hash: "deadbeef", name: "doc.pdf")
    }
    #expect(sleeper.delays.isEmpty)
    #expect(transport.requests.count == 2, "token plus one request, no retries")
}

@Test("After a 401 the request repeats with a fresh token")
func retriesOnceAfterUnauthorized() async throws {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    let payload = "contents"
    let transport = ScriptedTransport([
        .init(body: "user-1"),
        .init(status: 401),
        .init(body: "user-2"),
        .init(body: payload),
    ])
    let client = CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )

    let data = try await client.blob(hash: ContentHash.blob(Data(payload.utf8)), name: "doc.pdf")

    #expect(String(decoding: data, as: UTF8.self) == payload)
    #expect(transport.requests.count == 4)
    #expect(transport.requests.last?.value(forHTTPHeaderField: "rm-filename") == "doc.pdf")
}

@Test("A notification frame yields its event name")
func notificationEventName() {
    // The wrapper shape mirrors what the server actually sends: pub-sub
    // metadata around `message.attributes`.
    let frame = #"{"message":{"attributes":{"auth0UserID":"auth0|x""#
        + #","event":"SyncComplete","sourceDeviceID":"device-1""#
        + #"},"messageId":"1"},"subscription":"s"}"#
    let event = NotificationEvent(frame: .text(frame))
    #expect(event?.event == "SyncComplete")
    #expect(event?.device == "device-1")
    // Nothing is dropped on the way through: `rmctl watch` reports the fields
    // we have no name for yet, which is how the next one gets found.
    #expect(event?.attributes["auth0UserID"] == "auth0|x")
    // Parsing is best-effort: garbage must yield nil, never a crash.
    #expect(NotificationEvent(frame: .text("not json")) == nil)
}

@Test("Production hosts parse and speak HTTPS")
func productionEndpointsAreWellFormed() {
    // The invariant behind the force-unwrapped URL literals in
    // `CloudEndpoints.production`: if either string ever stops parsing,
    // this fails in tests instead of crashing at first launch.
    let endpoints = CloudEndpoints.production
    #expect(endpoints.authHost.scheme == "https")
    #expect(endpoints.syncHost.scheme == "https")
}
