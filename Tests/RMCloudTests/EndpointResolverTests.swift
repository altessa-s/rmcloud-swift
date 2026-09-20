// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Synchronization
import Testing

// Where this client sends a Bearer token is decided by `EndpointResolver`, and
// two of its inputs come from outside: a claim inside a token, and a public
// JSON file anybody's network can answer for. Both are checked here without a
// server — the transport is a port, so a captive portal, a foreign region and
// a host that is not there are all fixtures.

/// A user token carrying the claims a test wants to talk about.
private func token(region: String? = nil, expiringAt seconds: Int = 4_102_444_800) -> String {
    var claims: [String] = ["\"exp\": \(seconds)"]
    if let region { claims.append("\"tectonic\": \"\(region)\"") }
    return syntheticToken(claims: "{\(claims.joined(separator: ","))}")
}

/// A token provider holding a token that never needs buying.
private func provider(region: String?) throws -> TokenProvider {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    try secrets.save(token(region: region), as: .userToken)
    return TokenProvider(transport: ScriptedTransport([]), secrets: secrets)
}

/// A discovery answer as the live service shapes it: bare hosts, no scheme.
private func discovery(
    notifications: String,
    webapp: String = "webapp-prod.cloud.remarkable.engineering"
) -> ScriptedTransport.Reply {
    .init(body: #"{"notifications":"\#(notifications)","webapp":"\#(webapp)","mqttbroker":"vernemq-prod.cloud.remarkable.engineering"}"#)
}

// MARK: - The region comes from the token, and from nowhere else

@Test("The account's region names the sync host")
func theClaimNamesTheSyncHost() async throws {
    let resolver = EndpointResolver(tokens: try provider(region: "eu"))
    #expect(await resolver.endpoints().syncHost.host() == "eu.tectonic.remarkable.com")
    // The auth host is not the region's business: tokens are redeemed where
    // this build says, and the claim does not move that.
    #expect(await resolver.endpoints().authHost == CloudEndpoints.production.authHost)
}

@Test("A token without the claim leaves the configured host alone")
func noClaimKeepsTheConfiguredHost() async throws {
    let resolver = EndpointResolver(tokens: try provider(region: nil))
    #expect(await resolver.endpoints().syncHost == CloudEndpoints.production.syncHost)
}

// A claim is a string from a server, and it lands in a hostname. Read
// straight, `"eu.evil.example.com/"` would have built a host that is not
// reMarkable's and been handed the token on the next request.
@Test("A claim that is not a plain region is refused", arguments: [
    "eu.evil.example.com", "eu/../us", "e", "toolongregionname", "", "ЕU", "eu ",
])
func aStrangeClaimIsRefused(claim: String) async throws {
    let resolver = EndpointResolver(tokens: try provider(region: claim))
    #expect(await resolver.endpoints().syncHost == CloudEndpoints.production.syncHost)
}

@Test("A pinned resolver goes where it was told, claim or no claim")
func pinnedIgnoresTheClaim() async throws {
    let fake = CloudEndpoints(
        authHost: URL(string: "https://127.0.0.1:8443")!,
        syncHost: URL(string: "https://127.0.0.1:8443")!
    )
    let transport = ScriptedTransport([discovery(notifications: "eu.tectonic.remarkable.com")])
    let resolver = EndpointResolver(
        configured: fake,
        pinned: true,
        transport: transport,
        tokens: try provider(region: "eu")
    )
    #expect(await resolver.endpoints().syncHost == fake.syncHost)
    #expect(await resolver.notificationsHost().host() == "127.0.0.1")
    // And it did not ask: whoever names a host has said where this client
    // goes, and a published file does not get a vote.
    #expect(transport.requests.isEmpty)
}

// MARK: - Discovery, and what may be believed of it

@Test("The published socket host is used when it belongs to our region")
func theSocketHostComesFromDiscovery() async throws {
    let transport = ScriptedTransport([discovery(notifications: "eu.tectonic.remarkable.com")])
    let resolver = EndpointResolver(transport: transport, tokens: try provider(region: "eu"))
    let host = await resolver.notificationsHost()
    #expect(host.host() == "eu.tectonic.remarkable.com")
    #expect(host.path() == "/notifications/ws/json/1")
    // Asked without a token: the path wants none, and sending one to a file
    // the whole world reads would be a gift.
    #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
}

// The resolved answer is a public static object, one for every account, and it
// names `eu`. An account in another region would be sent — with its Bearer
// token — to a region it does not belong to, on the word of a file that has
// never heard of it.
@Test("A published host from another region is not followed")
func aForeignRegionIsNotFollowed() async throws {
    let transport = ScriptedTransport([discovery(notifications: "eu.tectonic.remarkable.com")])
    let resolver = EndpointResolver(transport: transport, tokens: try provider(region: "us"))
    #expect(await resolver.notificationsHost().host() == "us.tectonic.remarkable.com")
}

@Test("A published host outside reMarkable's domains is refused", arguments: [
    "eu.tectonic.remarkable.com.evil.example", "evil.example", "eu.tectonic.remarkable.com:8443",
    "eu.tectonic.remarkable.com/ws", "https://eu.tectonic.remarkable.com",
])
func aForeignHostIsRefused(published: String) async throws {
    let transport = ScriptedTransport([discovery(notifications: published)])
    let resolver = EndpointResolver(transport: transport, tokens: try provider(region: "eu"))
    #expect(await resolver.notificationsHost().host() == "eu.tectonic.remarkable.com")
}

// A hotel network answers 200 and HTML for every address there is. Parsed
// loosely that is an endpoint list of one field nobody asked for; parsed as
// this path's own shape it is nothing at all.
@Test("A 200 that is not the answer leaves the fallback standing", arguments: [
    "<html><body>Sign in to the network</body></html>",
    "{\"notifications\": 7}",
    "[]",
    "",
])
func rubbishLeavesTheFallback(body: String) async throws {
    let transport = ScriptedTransport([.init(body: body)])
    let resolver = EndpointResolver(transport: transport, tokens: try provider(region: "eu"))
    #expect(await resolver.notificationsHost().host() == "eu.tectonic.remarkable.com")
}

@Test("Discovery is asked once, not once per request")
func discoveryIsCached() async throws {
    let transport = ScriptedTransport([discovery(notifications: "eu.tectonic.remarkable.com")])
    let resolver = EndpointResolver(transport: transport, tokens: try provider(region: "eu"))
    _ = await resolver.notificationsHost()
    _ = await resolver.notificationsHost()
    _ = await resolver.notificationsHost()
    #expect(transport.requests.count == 1)
}

// The second reply in the script is a failure, so a resolver that asked again
// would come back with the fallback rather than with the host it already had.
@Test("The answer outlives the hour it declares, and no longer")
func discoveryExpires() async throws {
    let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
    let transport = ScriptedTransport([
        discovery(notifications: "eu.tectonic.remarkable.com"),
        .init(status: 500, body: ""),
    ])
    let resolver = EndpointResolver(
        transport: transport,
        tokens: try provider(region: "eu"),
        now: { clock.withLock { $0 } }
    )
    #expect(await resolver.notificationsHost().host() == "eu.tectonic.remarkable.com")
    clock.withLock { $0 = $0.addingTimeInterval(3599) }
    _ = await resolver.notificationsHost()
    #expect(transport.requests.count == 1)
    clock.withLock { $0 = $0.addingTimeInterval(2) }
    _ = await resolver.notificationsHost()
    #expect(transport.requests.count == 2)
}

// MARK: - When the region host is not there at all

@Test("A host that does not answer is given up on, once")
func theRegionHostIsGivenUpOn() async throws {
    let resolver = EndpointResolver(tokens: try provider(region: "eu"))
    #expect(await resolver.endpoints().syncHost.host() == "eu.tectonic.remarkable.com")
    await resolver.syncHostFailed()
    #expect(await resolver.endpoints().syncHost == CloudEndpoints.production.syncHost)
    // And it does not creep back: the failure being avoided looks exactly
    // like the network coming and going.
    #expect(await resolver.endpoints().syncHost == CloudEndpoints.production.syncHost)
}

// Falling back is about the host we chose, not about the network being away.
// A device out of range answers `-1009` for every address equally, and reading
// that as "the region host is wrong" would move an account off its own host
// for a walk out of Wi-Fi range.
@Test("Only 'the host is not there' means the host is not there")
func whichFailuresMeanTheHostIsWrong() {
    #expect(CloudError.transport(code: URLError.cannotFindHost.rawValue).meansHostIsNotThere)
    #expect(CloudError.transport(code: URLError.cannotConnectToHost.rawValue).meansHostIsNotThere)
    #expect(CloudError.transport(code: URLError.dnsLookupFailed.rawValue).meansHostIsNotThere)
    #expect(!CloudError.transport(code: URLError.notConnectedToInternet.rawValue).meansHostIsNotThere)
    #expect(!CloudError.transport(code: URLError.timedOut.rawValue).meansHostIsNotThere)
    #expect(!CloudError.http(status: 404, path: "/sync/v4/root").meansHostIsNotThere)
}

// MARK: - The auth host is not up for discussion

/// A transport on which nothing answers, and whose discovery — were anybody to
/// ask it — names another auth host.
private final class MovedHostTransport: HTTPTransporting {
    private let seen = Mutex<[String]>([])

    var requests: [String] { seen.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host() ?? ""
        seen.withLock { $0.append("\(host)\(request.url?.path() ?? "")") }
        if request.url?.path().contains("discovery") == true {
            let body = #"{"webapp":"webapp-next.cloud.remarkable.engineering"}"#
            let response = HTTPURLResponse.fake(for: request)
            return (Data(body.utf8), response)
        }
        throw CloudError.transport(code: URLError.cannotFindHost.rawValue)
    }
}

// Where a one-time code becomes a device token is settled by the build and by
// nothing else. The published list is a public, unauthenticated file, and the
// device token outlives every other secret this client holds — so an auth host
// that does not answer is a failure to report, not a reason to go somewhere
// else. `EndpointResolver` reads `webapp` to compare it with what we ship and
// says so in the log; nothing acts on it.
@Test("A token is never bought anywhere but the configured auth host")
func theAuthHostIsNeverTakenFromDiscovery() async throws {
    let transport = MovedHostTransport()
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let tokens = TokenProvider(transport: transport, secrets: secrets)

    await #expect(throws: CloudError.transport(code: URLError.cannotFindHost.rawValue)) {
        _ = try await tokens.userToken()
    }
    // One request, to the host this build names. Discovery was not asked, and
    // the host it would have published was not tried.
    #expect(transport.requests == ["webapp-prod.cloud.remarkable.engineering/token/json/2/user/new"])
}

// MARK: - The rule the two above share

@Test("A bare hostname is only trusted inside reMarkable's own domains")
func trustedHostsAreNarrow() {
    #expect(CloudEndpoints.trustedHost(named: "eu.tectonic.remarkable.com") != nil)
    #expect(CloudEndpoints.trustedHost(named: "webapp-prod.cloud.remarkable.engineering") != nil)
    // Upper case is a hostname's own business; the rest are not hostnames.
    #expect(CloudEndpoints.trustedHost(named: "EU.Tectonic.Remarkable.com")?.host() == "eu.tectonic.remarkable.com")
    #expect(CloudEndpoints.trustedHost(named: "remarkable.com.evil.example") == nil)
    #expect(CloudEndpoints.trustedHost(named: "user@eu.tectonic.remarkable.com") == nil)
    #expect(CloudEndpoints.trustedHost(named: "eu.tectonic.remarkable.com#") == nil)
    #expect(CloudEndpoints.trustedHost(named: "") == nil)
}
