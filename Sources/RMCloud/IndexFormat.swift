// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import RMLog

/// The schema version of an index file. We read both, we write only v4.
/// Frozen, for the reason given on `CloudError`: this framework ships in lockstep
/// with whatever links it, and an exhaustive `switch` in a consumer is the point.
@frozen
public enum SchemaVersion: String, Sendable, CaseIterable {
    case v3 = "3"
    case v4 = "4"
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness
// the compiler derives — and that witness is internal, so it is absent from
// this module's symbol table when RMCloud is linked as a binary framework.
// The reference resolves in a release build, where the comparison is inlined,
// and fails to link in a debug one. Declaring `==` here puts the comparison
// behind an exported symbol, which costs nothing and keeps `@frozen`: a new
// case must still break a consumer's build rather than fall into an
// `@unknown default`.
extension SchemaVersion {
    public static func == (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

/// A line of the index: `hash:type:documentID:subfiles:size`.
public struct IndexEntry: Sendable, Hashable {
    /// The type of an ordinary file inside a document.
    public static let fileType = "0"
    /// A type value seen on document records on some accounts. Not a
    /// discriminator — `type` is an account property; see `isDocument`.
    public static let documentType = "80000000"

    public let hash: String
    public let type: String
    public let documentID: String
    public let subfiles: Int
    public let size: Int64

    public init(hash: String, type: String, documentID: String, subfiles: Int, size: Int64) {
        self.hash = hash
        self.type = type
        self.documentID = documentID
        self.subfiles = subfiles
        self.size = size
    }

    /// The identifier's last component: `<page>.rm` out of
    /// `<document>/<page>.rm`.
    ///
    /// Page records inside a document index carry the document in front of
    /// them, so this is not always the identifier itself.
    public var fileName: String {
        documentID.split(separator: "/").last.map(String.init) ?? documentID
    }

    /// The extension of that name, empty when it has none.
    ///
    /// Spelled out here rather than borrowed from `NSString.pathExtension`,
    /// because this is the rule `isDocument` rests on and the two have to
    /// answer together. Taken from the last component on purpose: a dot in
    /// the part before the slash is part of a document's name, not an
    /// extension of the page's.
    ///
    /// Empty does not mean "a document" inside a document index — an
    /// attachment can sit there under a bare UUID beside the `<uuid>.rm` of
    /// the same name. Only the root index makes that promise.
    public var fileExtension: String {
        let name = fileName
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// The last component without its extension — a page's own UUID, which is
    /// what `.content` names its pages by.
    public var fileBaseName: String {
        let name = fileName
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// A document in the root index, rather than a file inside one.
    ///
    /// By the shape of the identifier, not by `type`. That field is a
    /// property of the account and not of the record — both `0` and
    /// `80000000` have been seen on live accounts for the same kind of
    /// record — so a check on it answers differently for two users of the
    /// same build, which is the kind of bug that ships. A document is a
    /// bare UUID; a file inside one always carries an extension.
    public var isDocument: Bool { fileExtension.isEmpty }

    /// The name of a document's index file for the `rm-filename` header.
    /// Without the `.docSchema` extension the server answers 400.
    public var indexName: String { Self.indexName(forDocument: documentID) }

    /// The same name built from a bare document identifier — for callers
    /// that hold an `Item` rather than an index entry. One definition on
    /// purpose: the rule is enforced by the server (400 on any other name),
    /// and a second spelling of it would rot apart unnoticed.
    public static func indexName(forDocument documentID: String) -> String {
        "\(documentID).docSchema"
    }

    public var line: String {
        "\(hash):\(type):\(documentID):\(subfiles):\(size)"
    }
}

/// A parsed index file (`.docSchema`).
public struct DocumentIndex: Sendable, Hashable {
    public let schema: SchemaVersion
    public let entries: [IndexEntry]

    public init(schema: SchemaVersion, entries: [IndexEntry]) {
        self.schema = schema
        self.entries = entries
    }

    /// A document file by extension: `<uuid>.metadata`, `<uuid>.pdf` and so on.
    public func entry(withExtension ext: String) -> IndexEntry? {
        entries.first { $0.fileExtension == ext }
    }
}

public enum IndexParser {
    /// Parsing an index file.
    ///
    /// The format: the first line is the schema version; for v4 the second
    /// line is `0:.:<number of records>:<total size>`; then one line per
    /// record.
    public static func parse(_ text: String) throws -> DocumentIndex {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let header = lines.first, !header.isEmpty else {
            throw CloudError.malformedIndex(line: "", reason: "empty index")
        }
        guard let schema = SchemaVersion(rawValue: header) else {
            throw CloudError.unsupportedSchema(header)
        }
        lines.removeFirst()

        var declared: Int?
        if schema == .v4 {
            // The count line, `0:<owner>:<count>:<size>`. Its shape is
            // checked, not merely its presence: `removeFirst` on whatever
            // stands second would eat the first real record the day the line
            // went missing, and the library would lose a document without a
            // word. In `.editing` that is worse than a display fault — the
            // writer re-serialises the very list it parsed and puts it back,
            // so a record eaten here would disappear from the cloud.
            guard let line = lines.first, let count = countedRecords(in: line) else {
                throw CloudError.malformedIndex(
                    line: lines.first ?? "",
                    reason: "expected a v4 count line of the form 0:<owner>:<count>:<size>"
                )
            }
            lines.removeFirst()
            declared = count
        }

        let entries = try lines
            .filter { !$0.isEmpty }
            .map(parseEntry)

        // A counter that disagrees with the real number of records is not
        // fatal: losing the whole library over it is worse than showing it as
        // it is. Silent it should not be either — nothing looked at this
        // number before, and it is the only witness there is to a record
        // having gone astray on the way here.
        if let declared, declared != entries.count {
            Log.cloud.error(
                "index declares \(declared, .public) records but carries \(entries.count, .public)"
            )
        }

        return DocumentIndex(schema: schema, entries: entries)
    }

    /// How many records a v4 count line claims, or `nil` when the line is not
    /// a count line at all.
    ///
    /// The owner field is not checked against anything: it is `.` for the root
    /// and the document's own identifier inside one, and this parser is handed
    /// both without being told which.
    private static func countedRecords(in line: String) -> Int? {
        let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4,
              fields[0] == IndexEntry.fileType,
              let count = Int(fields[2]), count >= 0,
              Int64(fields[3]).map({ $0 >= 0 }) == true
        else { return nil }
        return count
    }

    /// One record of an index.
    ///
    /// Only the shape is enforced — five fields, two of them numbers. The
    /// values are deliberately taken as they come, and that is not an
    /// oversight: a record lives inside an index, and refusing the record
    /// fails the index. For the root that means the whole library, so a single
    /// odd number would cost every document rather than the one it belongs to.
    ///
    /// What the odd values actually do is dealt with where the blast radius is
    /// one document: an empty hash is refused by `blob` before the request, a
    /// hash that is not SHA-256 is the host's to report while it still shows
    /// the document, and totals are added up with `totalBytes`, which
    /// saturates instead of trapping.
    public static func parseEntry(_ line: String) throws -> IndexEntry {
        let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else {
            throw CloudError.malformedIndex(line: line, reason: "expected 5 fields, got \(fields.count)")
        }
        guard let subfiles = Int(fields[3]) else {
            throw CloudError.malformedIndex(line: line, reason: "subfiles field is not a number")
        }
        guard let size = Int64(fields[4]) else {
            throw CloudError.malformedIndex(line: line, reason: "size field is not a number")
        }
        return IndexEntry(
            hash: fields[0],
            type: fields[1],
            documentID: fields[2],
            subfiles: subfiles,
            size: size
        )
    }

    /// The root index: a version line, the count line, then the documents.
    ///
    /// Always v4 — by a comment in the rmapi sources the servers reject a new
    /// root index in the v3 format.
    public static func serializeRoot(_ entries: [IndexEntry]) -> String {
        serialize(entries, owner: rootOwner)
    }

    /// A document's index: the same shape as the root's, but the count line
    /// names the document instead of the root.
    ///
    /// A live record (`rmctl hashes <id>`) shows the shape:
    ///
    ///     4
    ///     0:0085b944-…-05f517591b16:6:11353
    ///     <hash>:0:0085b944-….content:0:4425
    ///
    /// The second line is not the root's alone, as a first reading of rmapi
    /// suggested — leaving it out is answered `400 {"message":"invalid doc
    /// schema"}`. Only the second field differs: `.` for the root, the
    /// document's own identifier here.
    public static func serializeDocument(_ entries: [IndexEntry], id: String) -> String {
        serialize(entries, owner: id)
    }

    /// What the count line names for the root: a bare dot, the way a
    /// filesystem spells "here".
    private static let rootOwner = "."

    /// Records go out in `documentID` order, and that is the server's rule
    /// rather than our tidiness.
    ///
    /// Tried against the live root, one change at a time
    /// (`rmctl rootprobe`): the root re-serialised unchanged is accepted and
    /// reproduces its own hash byte for byte; those very same records with
    /// one of them moved to the end are refused with `400 {"message":"invalid
    /// root schema"}`; a new record appended at the end is refused; the same
    /// new record inserted in order is accepted. Nothing but the order
    /// differs between the last two.
    ///
    /// Here rather than at the call sites because there is no caller for whom
    /// it is optional — and because the writer appended to the end for two
    /// days with nothing saying so until the server did.
    private static func serialize(_ entries: [IndexEntry], owner: String) -> String {
        let ordered = entries.sorted { $0.documentID < $1.documentID }
        let totalSize = ordered.totalBytes { $0.size }
        return join(
            [SchemaVersion.v4.rawValue, "0:\(owner):\(ordered.count):\(totalSize)"]
                + ordered.map(\.line)
        )
    }

    /// Every line is terminated, the last one included: rmapi writes a
    /// newline after each, and in content-addressed storage a byte of
    /// difference is a different hash.
    private static func join(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }
}

/// The protocol's three different hashes, easy to mix up.
public enum ContentHash {
    /// A blob's hash — the SHA-256 of its contents.
    public static func blob(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    /// The same blob hash, but over a file and in chunks: originals run to
    /// hundreds of megabytes, and there is no reason to read them into memory
    /// whole — that is precisely what downloading into a file avoids. The
    /// loop, with its cancellation check at every chunk, is `FileChunks`'s.
    public static func blob(contentsOf file: URL) throws -> String {
        var hasher = SHA256()
        try FileChunks.forEach(in: file, ofSize: chunkSize) { chunk in
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    /// The read chunk used when hashing a file.
    private static let chunkSize = 4 * 1024 * 1024

    /// A tree node's hash — the SHA-256 over the children's hashes, sorted by
    /// `documentID` and decoded from hex into bytes.
    public static func node(of entries: [IndexEntry]) throws -> String {
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.documentID < $1.documentID }) {
            guard let bytes = Data(hexEncoded: entry.hash) else {
                throw CloudError.malformedIndex(line: entry.line, reason: "hash is not hex")
            }
            hasher.update(data: bytes)
        }
        return hasher.finalize().hexString
    }
}

public extension Data {
    init?(hexEncoded string: String) {
        guard string.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

/// The bytes as lowercase hex, two characters each — the spelling of a hash in
/// the index this file reads and writes, and the one the service compares
/// against.
///
/// File-private, and a copy, for the reason given beside `URL.constant` in
/// `CloudEndpoints.swift`.
private extension Sequence where Element == UInt8 {
    var hexString: String {
        // A table and two shifts per byte, not `String(format:)`: the formatter
        // is fine for a digest of thirty-two bytes and is minutes for a
        // megabyte, and the same spelling serves both.
        let digits: [Character] = Array("0123456789abcdef")
        var out = ""
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }
}

/// Adding up byte counts without the possibility of a trap.
///
/// `+` on `Int64` traps on overflow, and every size added up here arrives from
/// the service rather than from us: an index states how large each of its files
/// is, and nothing checks the number. A library of real documents comes nowhere
/// near the ceiling — two records claiming `Int64.max` are what it would take —
/// but a host may be running this inside a process where a trap is a volume
/// falling out of the file system rather than a tool exiting with a message.
/// Saturating is the honest answer: past `Int64.max` bytes an exact total has
/// stopped meaning anything anyway.
///
/// File-private, and a copy, for the reason given beside `URL.constant` in
/// `CloudEndpoints.swift`.
private extension Sequence {
    func totalBytes(of size: (Element) throws -> Int64) rethrows -> Int64 {
        try reduce(Int64(0)) { total, element in
            let (sum, overflowed) = total.addingReportingOverflow(try size(element))
            return overflowed ? .max : sum
        }
    }
}
