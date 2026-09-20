// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud

// What a test needs before it can ask the client anything: a token that looks
// like one, and a client whose network is a script.
//
// Both were written out wherever they were wanted — the base64url dance eight
// times over, the client three — and copies of a fixture drift the way copies
// of a rule do: two of the eight already disagreed about which claims a token
// carries. Real tokens never appear in tests, and there is exactly one place
// here where a fake one is made.

/// A synthetic JWT carrying `claims`, which is the payload as JSON text.
///
/// The header and the signature are words. Nothing in this project verifies a
/// signature — the token arrives over TLS and its claims are read for the plan,
/// the region and the device — so the middle is the whole of what any test is
/// talking about.
func syntheticToken(claims: String) -> String {
    let encoded = Data(claims.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

/// A token that is alive until 2100 and says nothing else.
///
/// What a test uses when the token is a precondition rather than the subject:
/// it has to be fresh, or the client goes and buys another one and the script
/// answers a request the test never meant to make.
func liveToken() -> String {
    syntheticToken(claims: #"{"exp": \#(distantExpiry)}"#)
}

/// Far enough away that no test is ever run after it.
let distantExpiry = 4_102_444_800

/// A client whose network is a script and whose token is already in the store.
///
/// The store is the point. With a live user token in it the client buys none,
/// so `replies` are the requests under test and counting them means what it
/// says — which is what lets a test assert that a refusal cost exactly one
/// request. A test that is about the exchange itself scripts the exchange as
/// its first reply and builds its client by hand.
func clientWithStoredToken(
    _ replies: [ScriptedTransport.Reply]
) throws -> (CloudClient, ScriptedTransport) {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    try secrets.save(liveToken(), as: .userToken)
    let transport = ScriptedTransport(replies)
    return (
        CloudClient(transport: transport, tokens: TokenProvider(transport: transport, secrets: secrets)),
        transport
    )
}
