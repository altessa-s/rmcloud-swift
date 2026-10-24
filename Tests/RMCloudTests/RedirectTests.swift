// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RMCloud
import Testing

// What a redirect is allowed to carry.
//
// `URLSession` follows one on its own, and until now this package let it: all
// three delegates handed the request back exactly as it came, saying in as many
// words that they decided nothing. What travels on such a hop is the
// `Authorization` header — the user token — and a blob request is answered by
// storage, which is entitled to point at a signed URL on somebody else's host.
// The token is the one thing that must not go there.
//
// Two halves, as elsewhere: the rule, which is pure and can be asked every
// question; and the wiring, which needs a live session and a server, and which
// is the only way to know the rule is reached at all.

// MARK: - The rule

private let token = "Bearer a-user-token"

private func hop(from: String, to: String) -> URLRequest {
    var request = URLRequest(url: URL.constant(to))
    request.setValue(token, forHTTPHeaderField: "Authorization")
    return Redirects.following(request, from: URL.constant(from))
}

private func carriesToken(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "Authorization") == token
}

@Test("A redirect that stays on the origin keeps the token")
func aRedirectInsideTheOriginKeepsTheToken() {
    #expect(
        carriesToken(
            hop(
                from: "https://eu.tectonic.remarkable.com/sync/v3/files/abc",
                to: "https://eu.tectonic.remarkable.com/storage/abc"
            )
        )
    )
    // The port the scheme implies is the port it is on: an answer that spells
    // out 443 has not moved anywhere.
    #expect(
        carriesToken(hop(from: "https://sync.host/a", to: "https://sync.host:443/b"))
    )
    // Neither the scheme nor the host is case-sensitive, and a redirect that
    // only changes their spelling is not a redirect elsewhere.
    #expect(carriesToken(hop(from: "https://Sync.Host/a", to: "HTTPS://sync.host/b")))
}

@Test("A redirect that leaves the origin does not carry the token")
func aRedirectOffTheOriginDropsTheToken() {
    // The case this exists for: storage answers with a signed URL of its own,
    // on a host that is not reMarkable's.
    #expect(
        !carriesToken(
            hop(
                from: "https://eu.tectonic.remarkable.com/sync/v3/files/abc",
                to: "https://storage.googleapis.com/signed/abc?X-Goog-Signature=…"
            )
        )
    )
    // A hop down to plain HTTP is off the origin as surely as one to another
    // host, and it is the one that puts the token on the wire in the clear.
    #expect(!carriesToken(hop(from: "https://sync.host/a", to: "http://sync.host/b")))
    #expect(!carriesToken(hop(from: "https://sync.host/a", to: "https://sync.host:8443/b")))
    // A sibling under the same domain is still another host. Nothing in the
    // rule is about who owns the name.
    #expect(!carriesToken(hop(from: "https://sync.host/a", to: "https://other.host/b")))
}

@Test("A hop from nowhere identifiable does not carry the token")
func aHopFromAnUnknownOriginDropsTheToken() {
    var request = URLRequest(url: URL(string: "https://sync.host/b")!)
    request.setValue(token, forHTTPHeaderField: "Authorization")
    #expect(!carriesToken(Redirects.following(request, from: nil)))
}

@Test("A redirect carrying no token is handed on untouched")
func aRedirectWithoutATokenIsUntouched() {
    let request = URLRequest(url: URL(string: "https://storage.host/b")!)
    let following = Redirects.following(request, from: URL(string: "https://sync.host/a")!)
    #expect(following.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(following.url == request.url)
}

// MARK: - That the rule is reached

/// The header as it arrived, whatever case the loading system spelled it in.
private func authorization(seen at: URL, server: ScriptedServer) -> String? {
    server.headers(at)
        .first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?
        .value
}

/// A request with a token on it, the way every request in this package carries
/// one.
private func authorized(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(token, forHTTPHeaderField: "Authorization")
    return request
}

@Test("A small request redirected off the origin arrives without the token")
func aSmallRequestDropsTheTokenOffTheOrigin() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let target = server.expect(.init(chunks: [Data("the blob".utf8)]), host: "storage.invalid")
    let url = server.expect(.init(redirectsTo: target))
    let session = server.session(delegate: RedirectWatcher())
    defer { session.finishTasksAndInvalidate() }

    let (data, response) = try await URLSessionTransport(session: session).send(authorized(url))

    #expect(response.statusCode == 200)
    #expect(data == Data("the blob".utf8))
    #expect(authorization(seen: url, server: server) == token, "the first request went out without a token")
    #expect(
        authorization(seen: target, server: server) == nil,
        "the user token was carried to another origin: \(String(describing: authorization(seen: target, server: server)))"
    )
}

// The other half of the same rule. A redirect inside the origin is the same
// conversation, and a client that stripped the token there would answer its own
// requests with 401.
@Test("A small request redirected inside the origin keeps the token")
func aSmallRequestKeepsTheTokenInsideTheOrigin() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let target = server.expect(.init(chunks: [Data("the blob".utf8)]))
    let url = server.expect(.init(redirectsTo: target))
    let session = server.session(delegate: RedirectWatcher())
    defer { session.finishTasksAndInvalidate() }

    _ = try await URLSessionTransport(session: session).send(authorized(url))

    #expect(authorization(seen: target, server: server) == token, "a hop inside one origin lost the token")
}

// The path an original takes, and the one the protocol actually names as
// answering with a signed storage URL.
@Test("A download redirected off the origin arrives without the token")
func aDownloadDropsTheTokenOffTheOrigin() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let body = Data("the contents of an original".utf8)
    let target = server.expect(.init(chunks: [body]), host: "storage.invalid")
    let url = server.expect(.init(redirectsTo: target))
    let router = DownloadRouter()
    let session = server.session(delegate: router)
    defer { session.finishTasksAndInvalidate() }

    let (file, response) = try await router.run(
        authorized(url),
        ceiling: DownloadCeiling(limitBytes: .max),
        onProgress: { _, _ in },
        in: session
    )
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(response.statusCode == 200)
    #expect(authorization(seen: url, server: server) == token)
    #expect(authorization(seen: target, server: server) == nil, "the user token was carried to storage")
}
