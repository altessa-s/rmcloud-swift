// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Testing

// The two contracts this package has with what is outside it: the variables a
// shell sets to point it at a fake server, and the Keychain accounts the
// tokens were written under. Neither fails to compile when broken. A renamed
// variable reads nothing and looks like a server that stopped answering; a
// renamed account reads nothing and looks like a device that quietly
// disconnected.

// MARK: - Host overrides

private func url(_ text: String) throws -> URL {
    try #require(URL(string: text))
}

@Test("RMCLOUD_HOST points both hosts at once")
func readsTheGeneralHostOverride() throws {
    let fake = try url("https://fake.example")

    let endpoints = CloudEndpoints.fromEnvironment(["RMCLOUD_HOST": "https://fake.example"])

    #expect(endpoints.authHost == fake)
    #expect(endpoints.syncHost == fake)
}

@Test("A specific host outranks the general one")
func specificHostWins() throws {
    let endpoints = CloudEndpoints.fromEnvironment([
        "RMCLOUD_HOST": "https://both.example",
        "RMCLOUD_SYNC_HOST": "https://sync.example",
    ])

    #expect(endpoints.authHost == (try url("https://both.example")))
    #expect(endpoints.syncHost == (try url("https://sync.example")))
}

@Test("With nothing set, the hosts are production's")
func readsNothingWithoutAnOverride() {
    #expect(CloudEndpoints.fromEnvironment([:]) == .production)
    #expect(CloudEndpoints.fromEnvironment(["RMCLOUD_HOST": ""]) == .production)
}

@Test("Plain HTTP is taken on the loopback and nowhere else")
func refusesPlainHTTPOffTheLoopback() throws {
    // A fake server on this machine: nothing sent there leaves it.
    let local = CloudEndpoints.fromEnvironment(["RMCLOUD_HOST": "http://localhost:8080"])
    #expect(local.syncHost == (try url("http://localhost:8080")))
    let loopback = CloudEndpoints.fromEnvironment(["RMCLOUD_SYNC_HOST": "http://127.0.0.1:1"])
    #expect(loopback.syncHost == (try url("http://127.0.0.1:1")))
    #expect(loopback.authHost == CloudEndpoints.production.authHost)

    // Plain HTTP anywhere else hands the tokens to whoever is on the way, and
    // a value that is not a URL at all names nowhere.
    #expect(CloudEndpoints.fromEnvironment(["RMCLOUD_HOST": "http://fake.example"]) == .production)
    #expect(CloudEndpoints.fromEnvironment(["RMCLOUD_HOST": "ftp://fake.example"]) == .production)
    #expect(CloudEndpoints.fromEnvironment(["RMCLOUD_HOST": "not a url"]) == .production)
}

// MARK: - Keychain accounts

@Test("The Keychain account names are the ones every shipped version wrote")
func pinsTheSecretAccountNames() {
    // The raw values, not the cases: the cases may be renamed, the strings
    // may not, and this is the only place after the declaration where the
    // pairing is written down.
    #expect(CloudSecret.deviceToken.rawValue == "deviceToken")
    #expect(CloudSecret.deviceID.rawValue == "deviceID")
    #expect(CloudSecret.userToken.rawValue == "userToken")
    #expect(CloudSecret.allCases.count == 3)
}
