// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Testing

// What the user token says about itself, read straight out of its claims.
//
// This one arrived late, from a suite about library notifications in the
// application: the device a change came from is compared against the device this
// connection belongs to, and the second is a claim in the token. Reading a claim
// is the protocol's business wherever the comparison happens.

// The claim the service knows this client by. Read off the token rather than
// out of the store: it is the name the service itself puts on what we write.
@Test("The device is read from the token that bought the connection")
func theDeviceComesFromTheToken() {
    #expect(
        TokenProvider.device(fromUserToken: syntheticToken(claims: #"{"device-id": "RM02"}"#)) == "RM02"
    )
    #expect(TokenProvider.device(fromUserToken: syntheticToken(claims: #"{"device-id": ""}"#)) == nil)
    #expect(TokenProvider.device(fromUserToken: syntheticToken(claims: #"{"exp": 1}"#)) == nil)
    #expect(TokenProvider.device(fromUserToken: "not-a-token") == nil)
}
