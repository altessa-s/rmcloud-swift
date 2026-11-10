// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Testing

// A token is judged fresh by its own `exp`, and `exp` is the server's clock.
// On a Mac whose clock had run six hours ahead, every token the server issued
// — three hours of life by its own claims — read as three hours dead on
// arrival: it was dropped from the Keychain, so the extension never found the
// account, and the next request bought another, until the server answered 429.
// The token's `iat` says what time the server thinks it is, and that is what
// these tests hold the provider to.

private let serverNow = 1_794_313_113
private let threeHours = 10_800

/// A token the server issued at `serverNow`, good for three hours by its own
/// clock.
private func tokenIssuedNow() -> String {
    syntheticToken(claims: #"{"iat": \#(serverNow), "exp": \#(serverNow + threeHours)}"#)
}

@Test("iat is read like exp: a whole number or a double, nil when absent")
func issuedAtIsRead() {
    #expect(
        TokenProvider.issuedAt(of: syntheticToken(claims: #"{"iat": 1700000000}"#))
            == Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(
        TokenProvider.issuedAt(of: syntheticToken(claims: #"{"iat": 1700000000.5}"#))
            == Date(timeIntervalSince1970: 1_700_000_000.5)
    )
    #expect(TokenProvider.issuedAt(of: syntheticToken(claims: #"{"exp": 1}"#)) == nil)
    #expect(TokenProvider.issuedAt(of: "not-a-token") == nil)
}

@Test("A token bought on a Mac hours ahead of the server is kept and reused")
func aSkewedClockKeepsTheBoughtToken() async throws {
    let mac = Date(timeIntervalSince1970: TimeInterval(serverNow + 6 * 3600))
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let bought = tokenIssuedNow()
    let transport = ScriptedTransport([.init(body: bought)])
    let tokens = TokenProvider(transport: transport, secrets: secrets, now: { mac })

    #expect(try await tokens.userToken() == bought)
    // In the store: that is how the extension and `rmctl` learn the account.
    #expect(try secrets.secret(.userToken) == bought)
    // And in hand for the next request rather than bought again.
    #expect(try await tokens.userToken() == bought)
    #expect(transport.requests.count == 1, "the token was bought again")
    #expect(await tokens.clockSkew.map { Int($0) } == 6 * 3600)
}

@Test("A token bought on a Mac behind the server is judged by the server's clock too")
func aClockBehindTheServerIsAllowedFor() async throws {
    // Two hours behind: by this Mac's clock the token has five hours left,
    // by the server's three. The margin is five minutes, so both agree it
    // is fresh — the point is that the skew is measured negative and the
    // token is still kept and reused.
    let mac = Date(timeIntervalSince1970: TimeInterval(serverNow - 2 * 3600))
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let bought = tokenIssuedNow()
    let transport = ScriptedTransport([.init(body: bought)])
    let tokens = TokenProvider(transport: transport, secrets: secrets, now: { mac })

    #expect(try await tokens.userToken() == bought)
    #expect(try await tokens.userToken() == bought)
    #expect(transport.requests.count == 1)
    #expect(try secrets.secret(.userToken) == bought)
    #expect(await tokens.clockSkew.map { Int($0) } == -2 * 3600)
}

@Test("With the clocks agreeing nothing changes, and a token without iat measures nothing")
func agreeingClocksMeasureNoSkew() async throws {
    let mac = Date(timeIntervalSince1970: TimeInterval(serverNow + 2))
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let bought = tokenIssuedNow()
    let transport = ScriptedTransport([.init(body: bought)])
    let tokens = TokenProvider(transport: transport, secrets: secrets, now: { mac })
    #expect(try await tokens.userToken() == bought)
    #expect(try secrets.secret(.userToken) == bought)
    #expect(await tokens.clockSkew.map { Int($0) } == 2)

    let plain = InMemorySecrets()
    try plain.save("device", as: .deviceToken)
    let noIat = syntheticToken(claims: #"{"exp": \#(serverNow + threeHours)}"#)
    let other = ScriptedTransport([.init(body: noIat)])
    let unmeasured = TokenProvider(transport: other, secrets: plain, now: { mac })
    #expect(try await unmeasured.userToken() == noIat)
    #expect(await unmeasured.clockSkew == nil)
}

@Test("A dead token is still replaced once the skew is allowed for")
func aTokenPastItsLifeIsStillReplaced() async throws {
    // Six hours ahead, and the stored token — bought by an earlier process
    // — is four hours old by the server's clock: dead by either. One
    // purchase, kept.
    let mac = Date(timeIntervalSince1970: TimeInterval(serverNow + 6 * 3600))
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    let stale = syntheticToken(claims: #"{"iat": \#(serverNow - 4 * 3600), "exp": \#(serverNow - 3600)}"#)
    try secrets.save(stale, as: .userToken)
    let bought = tokenIssuedNow()
    let transport = ScriptedTransport([.init(body: bought)])
    let tokens = TokenProvider(transport: transport, secrets: secrets, now: { mac })

    #expect(try await tokens.userToken() == bought)
    #expect(try secrets.secret(.userToken) == bought)
    #expect(transport.requests.count == 1)
}
