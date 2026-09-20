// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import RMLog
import Testing

/// The lines as a person would see them. A message is built with tags and
/// rendered by whatever masker the process installed; a test renders it with
/// the shipped one and reads the result, which is the same thing the log
/// holds.
private extension [LogMessage] {
    func rendered() -> [String] { map { $0.rendered(with: DigestMasker()) } }
}

// A debug log is the one place where a mistake is not a wrong answer but a
// leaked credential, and it is written to be read by a person who is already
// past caring about anything else. So what it may print is held here, and the
// lines are built by pure functions precisely so that they can be.

@Test("The switch is off unless it is turned on, and reads what a person types", arguments: [
    (nil, WireLog.Level.off), ("", .off), ("no", .off), ("verbose", .off),
    ("headers", .headers), ("1", .headers), ("on", .headers), ("HEADERS", .headers),
    ("bodies", .bodies), ("full", .bodies), ("2", .bodies), ("Body", .bodies),
])
func theLevelIsReadFromTheEnvironment(value: String?, expected: WireLog.Level) {
    #expect(WireLog.Level(named: value) == expected)
}

// The token is the whole point of the masking, and `Authorization` is only the
// name we happen to expect: the field belongs to the server, and a header it
// decides to call `x-auth-token` carries the same thing.
@Test("A credential never reaches the log in the clear")
func credentialsAreMasked() {
    let masker = DigestMasker()
    let token = "eyJhbGciOiJI.eyJleHAiOjF9.signature"
    func printed(_ field: String, _ value: String) -> String {
        WireLog.headerLine(field: field, value: value, arrow: "  →").rendered(with: masker)
    }

    for field in ["Authorization", "authorization", "X-Auth-Token", "Cookie", "x-goog-signature"] {
        #expect(WireLog.tag(for: field) == .secret)
        let line = printed(field, "Bearer \(token)")
        #expect(!line.contains(token))
        #expect(!line.contains("eyJleHAiOjF9"))
    }
    // The scheme survives — telling a Bearer from a Basic in a log is worth
    // having, and it is not the secret.
    #expect(printed("Authorization", "Bearer \(token)").contains("Bearer <len:"))
    // A value with no scheme is masked whole rather than half.
    #expect(!printed("rm-token", token).contains(token))
    // Everything else is printed as it came: that is what the log is for.
    #expect(printed("rm-filename", "root.docSchema").hasSuffix("rm-filename: root.docSchema"))
    // Including the one header the rule above would otherwise close over: the
    // TTL hint is named like a credential and is a count of seconds.
    #expect(WireLog.tag(for: "rm-token-ttl-hint") == .public)
    #expect(printed("rm-token-ttl-hint", "4653").hasSuffix("4653"))
}

// The registration answer IS the device token and the renewal answer IS
// the user token: for those paths no masking can save a printed body.
@Test("The auth exchange's body is never printed, even at bodies")
func credentialExchangeBodiesStayOut() {
    let masker = DigestMasker()
    var request = URLRequest(
        url: URL.constant("https://webapp-prod.cloud.remarkable.engineering/token/json/2/user/new")
    )
    request.httpMethod = "POST"
    let response = HTTPURLResponse.fake(for: request, headers: ["Content-Type": "text/plain"])
    let lines = WireLog.describe(
        response, body: Data("header.eyJleHAiOjF9.signature".utf8), for: request, level: .bodies
    ).map { $0.rendered(with: masker) }.joined(separator: "\n")
    #expect(!lines.contains("eyJleHAiOjF9"))
    #expect(lines.contains("credential exchange"))

    // An ordinary body still prints — that is what the level is for.
    let plain = URLRequest(url: URL(string: "https://cloud.example/sync/v3/root")!)
    let ordinary = WireLog.describe(
        response, body: Data(#"{"hash":"h"}"#.utf8), for: plain, level: .bodies
    ).map { $0.rendered(with: masker) }.joined()
    #expect(ordinary.contains("hash"))
}

// A signed storage URL carries its signature in the query, and the request
// line is the first thing written for every request there is.
@Test("A URL is printed without its query")
func queriesAreNotPrinted() {
    let signed = URL(string: "https://storage.googleapis.com/blob?X-Goog-Signature=abcdef&Expires=1")!
    let printed = WireLog.safe(signed)
    #expect(!printed.contains("abcdef"))
    #expect(printed.contains("storage.googleapis.com/blob"))
    #expect(printed.contains("+2 query items"))
    // A plain URL keeps its path: the hash in it is the one readable thing.
    #expect(WireLog.safe(URL(string: "https://host/sync/v3/files/abc")!) == "https://host/sync/v3/files/abc")
}

@Test("Bodies are printed only when asked for, and only when they are readable")
func bodiesFollowTheLevelAndTheType() {
    let json = Data(#"{"hash":"abc"}"#.utf8)
    #expect(WireLog.bodyText(json, contentType: "application/json", level: .bodies) != nil)
    #expect(WireLog.bodyText(json, contentType: "text/plain; charset=utf-8", level: .bodies) != nil)
    #expect(WireLog.bodyText(json, contentType: "application/xml", level: .bodies) != nil)
    // Not at the lesser level, whatever the type.
    #expect(WireLog.bodyText(json, contentType: "application/json", level: .headers) == nil)
    // And never for the things that are documents.
    #expect(WireLog.bodyText(json, contentType: "application/pdf", level: .bodies) == nil)
    #expect(WireLog.bodyText(json, contentType: "application/octet-stream", level: .bodies) == nil)
    #expect(WireLog.bodyText(json, contentType: nil, level: .bodies) == nil)
}

// The ceiling is not politeness: a page of ink answers as `application/json`
// nowhere, but an index of ten thousand documents is text, and a log is no
// place for a megabyte of it.
@Test("A long body is cut, and says that it was")
func longBodiesAreCut() throws {
    let long = Data(String(repeating: "a", count: WireLog.bodyLimit * 2).utf8)
    let printed = try #require(WireLog.bodyText(long, contentType: "text/plain", level: .bodies))
    #expect(printed.count < long.count)
    #expect(printed.contains("\(long.count) bytes in all"))
}

@Test("A request is written as its line, its headers and nothing else")
func aRequestIsDescribed() throws {
    var request = URLRequest(url: URL(string: "https://eu.tectonic.remarkable.com/sync/v4/root")!)
    request.httpMethod = "GET"
    request.setValue("Bearer secret-token-value", forHTTPHeaderField: "Authorization")
    request.setValue("roothash", forHTTPHeaderField: "rm-filename")

    let lines = WireLog.describe(request, level: .headers).rendered()
    #expect(lines.first == "→ GET https://eu.tectonic.remarkable.com/sync/v4/root")
    #expect(lines.contains("  → rm-filename: roothash"))
    #expect(!lines.joined().contains("secret-token-value"))
    // Off is off: no line at all, whatever the request holds.
    #expect(WireLog.describe(request, level: .off).isEmpty)
}

@Test("A response is written with its status, its headers and its body")
func aResponseIsDescribed() throws {
    let url = URL(string: "https://host/sync/v3/check-files")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 400,
        httpVersion: "HTTP/1.1",
        headerFields: ["content-type": "application/json", "rm-token-ttl-hint": "4653"]
    ))
    let body = Data(#"{"message":"invalid root schema"}"#.utf8)

    let lines = WireLog.describe(response, body: body, for: request, level: .bodies).rendered()
    #expect(lines.first == "← 400 POST https://host/sync/v3/check-files")
    #expect(lines.contains("  ← rm-token-ttl-hint: 4653"))
    // The sentence in the body is the reason this level exists: a 400 from
    // this service explains itself there and nowhere else.
    #expect(lines.contains { $0.contains("invalid root schema") })
    // At the lesser level the same body is a size, not a sentence.
    let quiet = WireLog.describe(response, body: body, for: request, level: .headers).rendered()
    #expect(quiet.contains { $0.contains("\(body.count) bytes") })
    #expect(!quiet.contains { $0.contains("invalid root schema") })
}
