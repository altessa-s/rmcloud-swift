// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Testing

// What this package writes, byte for byte.
//
// The reading side is specified by the suites beside this one; the writing
// side was not, and it is the half whose output the tablet reads back. Every
// file here is content-addressed — a byte of difference is a different hash,
// a different upload and a different root — so the shape of what goes out is
// held to exact bytes where the format allows it, and to its fields where a
// test that spelled out the whole file would say nothing a reader could check.

// MARK: - CRC32C

@Test("CRC32C answers the Castagnoli check vectors, and not zip's CRC-32")
func crc32cMatchesTheCheckVectors() {
    // The standard vectors. The last line is the whole reason to have them: an
    // ordinary CRC-32 of the same nine digits is 0xCBF43926, a
    // plausible-looking number that the storage refuses.
    #expect(CRC32C.checksum(Data()) == 0x0000_0000)
    #expect(CRC32C.checksum(Data("a".utf8)) == 0xC1D0_4330)
    #expect(CRC32C.checksum(Data("abc".utf8)) == 0x364B_3FB7)
    #expect(CRC32C.checksum(Data("123456789".utf8)) == 0xE306_9283)
    #expect(CRC32C.checksum(Data(repeating: 0x00, count: 32)) == 0x8A91_36AA)
    #expect(CRC32C.checksum(Data(repeating: 0xFF, count: 32)) == 0x62A8_AB43)
    #expect(CRC32C.checksum(Data("123456789".utf8)) != 0xCBF4_3926)
}

@Test("The x-goog-hash value is the checksum big-endian, in base64, named")
func googHashSpellsTheHeader() {
    // 0xE3069283 big-endian is E3 06 92 83, which base64 spells `4waSgw==`.
    #expect(CRC32C.googHash(Data("123456789".utf8)) == "crc32c=4waSgw==")
    #expect(CRC32C.googHash(Data()) == "crc32c=AAAAAA==")
}

@Test("A file's checksum and hash agree with its bytes', across chunk boundaries")
func fileSumsAgreeWithMemory() throws {
    // Two chunks and a bit: the file variant reads a megabyte at a time and
    // the hash four, and a sum that only agreed inside one chunk would pass
    // on every fixture small enough to fit.
    var bytes = [UInt8](repeating: 0, count: 2 * (1 << 20) + 17)
    for index in bytes.indices {
        bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
    }
    let data = Data(bytes)
    let file = try ScratchFile.write(data)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(try CRC32C.checksum(contentsOf: file) == CRC32C.checksum(data))
    #expect(try CRC32C.googHash(contentsOf: file) == CRC32C.googHash(data))
    #expect(try ContentHash.blob(contentsOf: file) == ContentHash.blob(data))
}

// MARK: - Metadata

/// A moment with a fraction in it, so that the rounding is exercised: the
/// tablet counts milliseconds, and half a millisecond has to go somewhere.
private let moment = Date(timeIntervalSince1970: 1_700_000_000.5)
private let momentText = "1700000000500"

private func fields(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test("A new folder's metadata is exactly what the tablet writes for one")
func writesAFolder() throws {
    let data = try MetadataWriting.folder(named: "Notes", parent: nil, modified: moment)

    // Exact bytes, on purpose. Sorted keys and no whitespace are what make
    // the same folder hash the same every time it is written, and a key
    // that moved would be a different blob under a different hash.
    #expect(
        String(decoding: data, as: UTF8.self) == #"{"deleted":false,"lastModified":"1700000000500","#
            + #""metadatamodified":false,"modified":false,"parent":"","pinned":false,"synced":true,"#
            + #""type":"CollectionType","version":1,"visibleName":"Notes"}"#
    )
    #expect(try MetadataWriting.folder(named: "Notes", parent: nil, modified: moment) == data)
}

@Test("A new document's metadata carries the five fields a folder's does not")
func writesADocument() throws {
    let object = try fields(MetadataWriting.document(named: "Paper", parent: "folder-1", modified: moment))

    #expect(object["type"] as? String == "DocumentType")
    #expect(object["parent"] as? String == "folder-1")
    #expect(object["lastModified"] as? String == momentText)
    #expect(object["createdTime"] as? String == momentText)
    // Unopened: no page it was left on, and no time it was opened.
    #expect((object["lastOpened"] as? String)?.isEmpty == true)
    #expect(object["lastOpenedPage"] as? Int == -1)
    #expect(object["new"] as? Bool == true)
    #expect((object["source"] as? String)?.isEmpty == true)
    #expect(object.count == 15)
}

@Test("A rename changes the name, raises the version and keeps every other field")
func renamesAndKeepsTheRest() throws {
    let text = #"{"visibleName":"Old","parent":"","type":"DocumentType","version":3,"#
        + #""metadatamodified":false,"lastModified":"1","firmwareField":"kept"}"#
    let record = Data(text.utf8)

    let object = try fields(MetadataWriting.renamed(record, to: "New", modified: moment))

    #expect(object["visibleName"] as? String == "New")
    #expect(object["version"] as? Int == 4)
    #expect(object["metadatamodified"] as? Bool == true)
    #expect(object["lastModified"] as? String == momentText)
    // The field this build has never heard of passes through: it is the
    // user's document, not ours.
    #expect(object["firmwareField"] as? String == "kept")
}

@Test("A record without a version or the flag is not given either")
func doesNotInventFieldsOnARecordThatLacksThem() throws {
    // A notebook made on current firmware carries neither, and adding a field
    // of ours to somebody else's document is what the writer goes out of its
    // way not to do.
    let record = Data(#"{"visibleName":"Old","parent":"","type":"DocumentType"}"#.utf8)

    let object = try fields(MetadataWriting.renamed(record, to: "New", modified: moment))

    #expect(object["version"] == nil)
    #expect(object["metadatamodified"] == nil)
    #expect(object["visibleName"] as? String == "New")
}

@Test("A rewrite is about the pages: the version moves, the metadata flag does not")
func rewriteLeavesTheMetadataFlagAlone() throws {
    let record = Data(
        #"{"visibleName":"Paper","version":3,"metadatamodified":false,"lastOpenedPage":9}"#.utf8
    )

    let clamped = try fields(MetadataWriting.rewritten(record, modified: moment, pageCount: 4))
    #expect(clamped["version"] as? Int == 4)
    #expect(clamped["metadatamodified"] as? Bool == false)
    #expect(clamped["lastModified"] as? String == momentText)
    // A reading position past the new last page is brought back onto it.
    #expect(clamped["lastOpenedPage"] as? Int == 3)

    // With no page count there is nothing to clamp to, and the position stays.
    let unclamped = try fields(MetadataWriting.rewritten(record, modified: moment))
    #expect(unclamped["lastOpenedPage"] as? Int == 9)
}

@Test("A star that is already there is not written again")
func favoriteIsIdempotentByteForByte() throws {
    let record = Data(#"{"pinned":true,"version":3,"visibleName":"Paper"}"#.utf8)

    // Identity, not equivalence: the same bytes hash the same, so the commit
    // finds the root unchanged and nothing is uploaded.
    #expect(try MetadataWriting.favorited(record, true, modified: moment) == record)

    let starred = try fields(MetadataWriting.favorited(record, false, modified: moment))
    #expect(starred["pinned"] as? Bool == false)
    #expect(starred["version"] as? Int == 4)
}

@Test("The trash is a parent, and leaving it puts the parent and the flag back")
func trashesAndRestoresByParent() throws {
    let record = Data(#"{"parent":"folder-1","deleted":true,"version":1,"visibleName":"Paper"}"#.utf8)

    let trashed = try fields(MetadataWriting.movedToTrash(record, modified: moment))
    #expect(trashed["parent"] as? String == "trash")
    // `deleted` is left exactly as it was: setting it is what makes a record
    // unrecoverable, and the trash is the recoverable state.
    #expect(trashed["deleted"] as? Bool == true)
    #expect(trashed["version"] as? Int == 2)

    let restored = try fields(MetadataWriting.restored(record, to: nil, modified: moment))
    #expect((restored["parent"] as? String)?.isEmpty == true)
    #expect(restored["deleted"] as? Bool == false)

    let moved = try fields(MetadataWriting.moved(record, to: "folder-2", modified: moment))
    #expect(moved["parent"] as? String == "folder-2")
}

@Test("Milliseconds are rounded, and spelled as the tablet spells them")
func millisecondsRoundAndSpell() {
    #expect(MetadataWriting.milliseconds(Date(timeIntervalSince1970: 1.0004)) == "1000")
    #expect(MetadataWriting.milliseconds(Date(timeIntervalSince1970: 1.0006)) == "1001")
    // The `.content` stamp is the same clock as a number, not a string.
    #expect(ContentTagWriting.milliseconds(Date(timeIntervalSince1970: 1.0006)) == 1001)
}

// MARK: - Content tags

private let content = Data(
    #"{"cPages":{"pages":[]},"tags":[{"name":"work","timestamp":1690000000000}],"zoomMode":"bestFit"}"#.utf8
)

private func tags(_ object: [String: Any]) throws -> [(name: String, stamp: Int64)] {
    try #require(object["tags"] as? [[String: Any]]).map { tag in
        (tag["name"] as? String ?? "", (tag["timestamp"] as? NSNumber)?.int64Value ?? -1)
    }
}

@Test("Tagging keeps the stamp of a tag already there and stamps only the new one")
func tagsKeepTheirStamps() throws {
    let object = try fields(ContentTagWriting.tagged(content, ["home", "work"], now: moment))

    let written = try tags(object)
    #expect(written.map(\.name) == ["home", "work"])
    #expect(written.map(\.stamp) == [1_700_000_000_500, 1_690_000_000_000])
    // The rest of the file is the user's document and passes through.
    #expect(object["zoomMode"] as? String == "bestFit")
    #expect(object["cPages"] != nil)
}

@Test("Tags that already read like this are not written at all")
func taggingIsIdempotentByteForByte() throws {
    #expect(try ContentTagWriting.tagged(content, ["work"], now: moment) == content)
}

@Test("A rewritten .content carries the old tags across and adds what a send puts on")
func carriesTagsIntoARewrite() throws {
    let rewritten = Data(#"{"cPages":{"pages":["p1"]}}"#.utf8)

    let object = try fields(
        ContentTagWriting.carryingTags(from: content, into: rewritten, adding: ["work", "sent"], now: moment)
    )

    let written = try tags(object)
    #expect(written.map(\.name) == ["work", "sent"])
    #expect(written.map(\.stamp) == [1_690_000_000_000, 1_700_000_000_500])
    #expect(object["cPages"] != nil)
}

// The old file used to be read with `try?`: one that did not parse counted as
// one without tags, and the rewrite went through with the labels gone. The
// loss this function exists to prevent, caused by the function itself.
@Test("A rewrite whose old .content cannot be read is refused, not stripped of its tags")
func refusesToCarryTagsFromAnUnreadableContent() {
    let rewritten = Data(#"{"cPages":{"pages":["p1"]}}"#.utf8)

    #expect(throws: CloudError.self) {
        try ContentTagWriting.carryingTags(from: Data("not json".utf8), into: rewritten, adding: ["sent"], now: moment)
    }
    // A JSON array is not a `.content` either: the file is an object or it is
    // not the file.
    #expect(throws: CloudError.self) {
        try ContentTagWriting.carryingTags(from: Data("[]".utf8), into: rewritten, adding: ["sent"], now: moment)
    }
}

@Test("A .content that never had tags carries none across and still takes what a send puts on")
func carriesNoTagsFromAnUntaggedContent() throws {
    let rewritten = Data(#"{"cPages":{"pages":["p1"]}}"#.utf8)

    // No `tags` key at all: the ordinary state of a document nobody labelled.
    let untagged = Data(#"{"cPages":{"pages":[]},"zoomMode":"bestFit"}"#.utf8)
    let fromUntagged = try tags(fields(
        ContentTagWriting.carryingTags(from: untagged, into: rewritten, adding: ["sent"], now: moment)
    ))
    #expect(fromUntagged.map(\.name) == ["sent"])
    #expect(fromUntagged.map(\.stamp) == [1_700_000_000_500])

    // The key with something else under it is read the same way: not a list
    // of tags, so nothing to carry.
    let odd = Data(#"{"cPages":{"pages":[]},"tags":"work"}"#.utf8)
    let fromOdd = try tags(fields(
        ContentTagWriting.carryingTags(from: odd, into: rewritten, adding: ["sent"], now: moment)
    ))
    #expect(fromOdd.map(\.name) == ["sent"])
}

// MARK: - A document's index

@Test("A document's index names the document on its count line and sorts its records")
func serializesADocumentIndex() throws {
    // Out of order on purpose: the server refuses any other order, and the
    // sort is the serializer's job rather than the caller's.
    let entries = [
        IndexEntry(hash: "bb", type: "0", documentID: "doc/b.rm", subfiles: 0, size: 5),
        IndexEntry(hash: "aa", type: "0", documentID: "doc/a.metadata", subfiles: 0, size: 7),
    ]

    let text = IndexParser.serializeDocument(entries, id: "doc")

    #expect(text == "4\n0:doc:2:12\naa:0:doc/a.metadata:0:7\nbb:0:doc/b.rm:0:5\n")
    let parsed = try IndexParser.parse(text)
    #expect(parsed.schema == .v4)
    #expect(parsed.entries == entries.sorted { $0.documentID < $1.documentID })
}

@Test("A total that would overflow saturates instead of trapping")
func indexTotalSaturates() {
    let entries = [
        IndexEntry(hash: "aa", type: "0", documentID: "a", subfiles: 0, size: .max),
        IndexEntry(hash: "bb", type: "0", documentID: "b", subfiles: 0, size: .max),
    ]

    let text = IndexParser.serializeDocument(entries, id: "doc")

    #expect(text.split(separator: "\n")[1] == "0:doc:2:\(Int64.max)")
}

// MARK: - What is read back

@Test("A document's metadata is resolved into what the library reasons about")
func decodesDocumentState() throws {
    let text = #"{"visibleName":"Paper","parent":"","type":"DocumentType","deleted":false,"pinned":true,"#
        + #""lastModified":"1700000000500","createdTime":"1600000000000","version":3}"#
    let record = Data(text.utf8)

    let state = try DocumentState.decode(record)

    #expect(state.visibleName == "Paper")
    #expect(state.parentID == nil)
    #expect(!state.isFolder)
    #expect(!state.isTemplate)
    #expect(!state.isTrashed)
    #expect(state.pinned == true)
    #expect(state.modifiedDate == Date(timeIntervalSince1970: 1_700_000_000.5))
    #expect(state.createdDate == Date(timeIntervalSince1970: 1_600_000_000))
}

@Test("A folder, a trashed record and a template are told apart by the wire's own fields")
func decodesTheOtherKindsOfRecord() throws {
    let folder = try DocumentState.decode(Data(#"{"visibleName":"F","type":"CollectionType","parent":"p"}"#.utf8))
    #expect(folder.isFolder)
    #expect(folder.parentID == "p")
    // No `createdTime` on a folder, and no 1970 invented for it either.
    #expect(folder.createdDate == nil)
    #expect(folder.modifiedDate == .distantPast)

    let trashed = try DocumentState.decode(Data(#"{"visibleName":"T","type":"DocumentType","parent":"trash"}"#.utf8))
    #expect(trashed.isTrashed)
    #expect(trashed.parentID == nil)

    let template = try DocumentState.decode(Data(#"{"visibleName":"L","type":"TemplateType"}"#.utf8))
    #expect(template.isTemplate)

    // An unfamiliar type is a document, as it was before the enum existed.
    let odd = try DocumentState.decode(Data(#"{"visibleName":"O","type":"SomethingNew"}"#.utf8))
    #expect(!odd.isFolder)
    #expect(!odd.isTemplate)
}

@Test("A document's tags are read once each, empty names dropped, in the file's order")
func decodesContentTags() throws {
    #expect(try DocumentContentState.decode(Data("{}".utf8)).tags.isEmpty)

    let state = try DocumentContentState.decode(
        Data(#"{"tags":[{"name":"b"},{"name":""},{"name":"a"},{"name":"b"}],"pageTags":[{"name":"x"}]}"#.utf8)
    )
    #expect(state.tags == ["b", "a"])
}
