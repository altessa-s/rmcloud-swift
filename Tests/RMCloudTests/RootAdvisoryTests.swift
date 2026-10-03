// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Testing

// The root pointer carries more than a hash and a generation, and this client
// obeys none of it. What it does instead is notice.
//
// On a live account, both root paths answer with exactly four fields:
//
//     {"hash":"…","generation":…,"schemaVersion":4,"deletedImmutableAction":"rollback"}
//
// `maxNetworkJobs`, `hasMissingHashes` and `missingHashes` are in the protocol
// notes and not on the wire — so a client that followed the concurrency hint
// would be following nothing. The reason to read the rest is the day one of
// them changes: `deletedImmutableAction` is an instruction about deletion, the
// service moves it on the fly, and this client deletes for real — tombstones in
// the index, files in the mirror.

/// What every account has answered so far.
private let live = RootAdvisory(
    schemaVersion: 4,
    deletedImmutableAction: "rollback",
    maxNetworkJobs: nil,
    hasMissingHashes: nil,
    missingHashes: nil
)

// MARK: - What is ordinary

@Test("The state every live account answers with is not news")
func theLiveStateIsOrdinary() {
    #expect(live.isOrdinary)
    // A body with the two fields alone — the shape some accounts answer `v3`
    // with — says nothing at all, and silence is ordinary too.
    #expect(RootAdvisory().isOrdinary)
    // `rollback` came from the server in lower case while the client declares
    // the six names in PascalCase, so the comparison cannot be case-sensitive.
    #expect(RootAdvisory(deletedImmutableAction: "Rollback").isOrdinary)
    #expect(RootAdvisory(deletedImmutableAction: "None").isOrdinary)
    #expect(RootAdvisory(schemaVersion: 3).isOrdinary)
}

@Test("The service asking for something this client does not implement is news")
func theUnfamiliarIsNews() {
    // The directive that would have this client put back what it deleted, or
    // delete without leaving a tombstone. Both are machinery we do not have.
    #expect(RootAdvisory(deletedImmutableAction: "RemoveWithoutTombstone").isOrdinary == false)
    #expect(RootAdvisory(deletedImmutableAction: "RestoreAfterFailedVerification").isOrdinary == false)
    // A schema the index parser would refuse anyway — better to hear it from
    // the pointer than from a library that stopped reading.
    #expect(RootAdvisory(schemaVersion: 5).isOrdinary == false)
    // Fields that have never been sent. Their appearing is itself the news.
    #expect(RootAdvisory(maxNetworkJobs: 8).isOrdinary == false)
    #expect(RootAdvisory(hasMissingHashes: true).isOrdinary == false)
    #expect(RootAdvisory(missingHashes: 3).isOrdinary == false)
    // Nought missing hashes is not missing hashes.
    #expect(RootAdvisory(hasMissingHashes: false, missingHashes: 0).isOrdinary)
    // Firmware 3.29 reads a switch off HTTP/2 from the same body: asked for,
    // it is news; declined, it is not.
    #expect(RootAdvisory(disableHTTP2: true).isOrdinary == false)
    #expect(RootAdvisory(disableHTTP2: false).isOrdinary)
}

// MARK: - What is said, and when

// The root is read on every tick of the poller. A line per read would bury the
// one line that matters under a day of identical ones.
@Test("A pointer that says what it said before is not remarked on")
func anUnchangedPointerIsSilent() {
    #expect(live.remarks(since: live).isEmpty)
}

@Test("The first sighting is described whole")
func theFirstSightingIsDescribed() {
    let remarks = live.remarks(since: nil)
    #expect(remarks == ["schema 4", "deletedImmutableAction rollback"])
    // A pointer with nothing but the two fields we act on has nothing to say.
    #expect(RootAdvisory().remarks(since: nil).isEmpty)
}

@Test("A directive that changes is spelled out both ways round")
func aChangedDirectiveIsSpelledOut() {
    var moved = live
    moved.deletedImmutableAction = "RemoveWithoutTombstone"

    #expect(
        moved.remarks(since: live)
            == ["deletedImmutableAction rollback → RemoveWithoutTombstone"]
    )
    #expect(moved.isOrdinary == false)
}

// A field the service stops sending is the same kind of news as one it changes:
// a directive that has gone is a directive that no longer says what it said.
@Test("A field that disappears is a change like any other")
func aVanishedFieldIsAChange() {
    var gone = live
    gone.deletedImmutableAction = nil

    #expect(gone.remarks(since: live) == ["deletedImmutableAction rollback → nothing"])
}

@Test("A hint that appears is named, and named as not followed")
func anAppearingHintIsNamed() {
    var hinted = live
    hinted.maxNetworkJobs = 4

    let remarks = hinted.remarks(since: live)
    #expect(remarks.count == 1)
    // Joined rather than unwrapped: the count above already says there is one,
    // and an empty list fails the two below by saying nothing.
    let hint = remarks.joined()
    #expect(hint.contains("maxNetworkJobs nothing → 4"))
    // Said in the same breath, because a log line that names a limit reads as
    // a limit being kept.
    #expect(hint.contains("not followed"))
}

@Test("A switch off HTTP/2 is named, and named as not followed")
func anHTTP2SwitchIsNamed() {
    var switched = live
    switched.disableHTTP2 = true

    let remarks = switched.remarks(since: live)
    #expect(remarks.count == 1)
    let hint = remarks.joined()
    #expect(hint.contains("disableHTTP2 nothing → true"))
    #expect(hint.contains("not followed"))
    #expect(switched.remarks(since: nil).contains { $0.hasPrefix("disableHTTP2 true") })
}

@Test("Missing hashes are reported by their number, and their going away too")
func missingHashesAreCounted() {
    var lacking = live
    lacking.hasMissingHashes = true
    lacking.missingHashes = 12

    #expect(lacking.remarks(since: live) == ["the server reports 12 hashes it does not hold"])
    #expect(live.remarks(since: lacking) == ["the server no longer reports missing hashes"])
}

// MARK: - That the pointer is read at all

/// A client answering one scripted root body.
private func client(root body: String) throws -> CloudClient {
    try clientWithStoredToken([.init(body: body)]).0
}

// The fields are optional because they are: three of them have never been sent,
// and some accounts answer `v3` with the two we act on and nothing else. A
// decoder that required any of them would refuse the pointer — which is the
// library, for a field nobody reads.
@Test("Every shape of the pointer decodes, from the barest to the whole eight")
func everyPointerShapeDecodes() async throws {
    let bare = try await client(root: #"{"hash":"abc","generation":1}"#).root()
    #expect(bare == CloudRoot(hash: "abc", generation: 1))

    // The live shape.
    let measured = try await client(
        root: #"{"hash":"abc","generation":2,"schemaVersion":4,"deletedImmutableAction":"rollback"}"#
    ).root()
    #expect(measured.generation == 2)

    // And the shape the protocol notes describe, which nothing has answered
    // with yet.
    let whole = try await client(root: """
        {"hash":"abc","generation":3,"schemaVersion":4,"hasMissingHashes":true,\
        "missingHashes":["aa","bb"],"maxNetworkJobs":6,"deletedImmutableAction":"rollback",\
        "disableHTTP2":false}
        """).root()
    #expect(whole.generation == 3)
}
