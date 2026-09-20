// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Writing `<uuid>.metadata` — the one document file whose contents we compose
/// ourselves instead of passing through.
///
/// The edit works on the raw JSON object rather than on `DocumentMetadata`.
/// That type is a read model of the fields this Mac needs; the tablet's own
/// metadata carries more — `version`, `synced`, `metadatamodified`, and
/// whatever the next firmware adds. Re-encoding the `Decodable` would silently
/// drop the rest, and those fields belong to the user's document, not to us.
public enum MetadataWriting {
    /// The metadata of a freshly created folder.
    ///
    /// An empty `parent` is the library root — the same spelling the tablet
    /// uses, and not to be confused with `"trash"`.
    public static func folder(named name: String, parent: String?, modified: Date) throws -> Data {
        try encode([
            "visibleName": name,
            "type": "CollectionType",
            "parent": parent ?? "",
            "deleted": false,
            "pinned": false,
            "synced": true,
            "metadatamodified": false,
            "modified": false,
            "version": 1,
            "lastModified": milliseconds(modified),
        ])
    }

    /// The metadata of a freshly uploaded document.
    ///
    /// Five fields more than a folder's, and each was on the live record
    /// dumped from a live account — `createdTime`, `lastOpened`, `lastOpenedPage`,
    /// `new` and `source`. They cost nothing to write and cannot be added
    /// later without a second write, so they go out from the start.
    ///
    /// `lastOpened` is deliberately empty rather than "now": nobody has
    /// opened this document yet, and saying otherwise would put it at the top
    /// of the tablet's recents having never been read.
    public static func document(named name: String, parent: String?, modified: Date) throws -> Data {
        let stamp = milliseconds(modified)
        return try encode([
            "visibleName": name,
            "type": "DocumentType",
            "parent": parent ?? "",
            "deleted": false,
            "pinned": false,
            "synced": true,
            "metadatamodified": false,
            "modified": false,
            "version": 1,
            "lastModified": stamp,
            "createdTime": stamp,
            "lastOpened": "",
            // Minus one, not nought: an unopened document has no page it was
            // left on, and nought is the tablet's way of saying "the first
            // one". The same reasoning as the empty `lastOpened` above —
            // nobody has read this yet, and saying otherwise invents a
            // history the user does not have.
            "lastOpenedPage": -1,
            // Not seen on the tablet yet — this is what the flag is for, and
            // it is how a new arrival gets marked in the library.
            "new": true,
            // Where the document came from. A real account's record carries
            // an empty string here, and we have nothing truer to put.
            "source": "",
        ])
    }

    /// The same metadata under a new name.
    ///
    /// Only `visibleName` changes. Everything else the record carries — the
    /// parent, the creation time, the reading position, the fields the next
    /// firmware invents — belongs to the user's document and passes through
    /// untouched.
    ///
    /// `version` goes up and `metadatamodified` is set for the same reason
    /// trashing does it: every writer of a document file is expected to raise
    /// the version, and the flag says the change was to the metadata rather
    /// than to the pages.
    public static func renamed(_ data: Data, to name: String, modified: Date) throws -> Data {
        var object = try decode(data)
        object["visibleName"] = name
        markEdited(&object, at: modified)
        return try encode(object)
    }

    /// The same record over new files: the document's own bytes were
    /// written again, so `version` goes up and `lastModified` is now, and
    /// nothing else moves — the name, the folder and what the tablet keeps
    /// of its own are the record's, not the writer's. `metadatamodified`
    /// stays as it was: the change was to the content, which is the one
    /// thing that flag says it was not.
    /// `pageCount` is the new content's, so a reading position past the
    /// last page is brought back onto it — where the record keeps one.
    public static func rewritten(_ data: Data, modified: Date, pageCount: Int? = nil) throws -> Data {
        var object = try decode(data)
        raiseVersion(of: &object)
        object["lastModified"] = milliseconds(modified)
        if let pageCount, pageCount > 0, let opened = object["lastOpenedPage"] as? Int, opened >= pageCount {
            object["lastOpenedPage"] = pageCount - 1
        }
        return try encode(object)
    }

    /// The same metadata under a new parent.
    ///
    /// An empty parent is the library root — the same spelling the tablet
    /// uses. The trash is **not** a destination here: it is reached by
    /// `movedToTrash`, which is a different operation with a different
    /// meaning, and letting a plain move write "trash" would throw a document
    /// away while telling the user it had been filed.
    public static func moved(_ data: Data, to parent: String?, modified: Date) throws -> Data {
        var object = try decode(data)
        object["parent"] = parent ?? ""
        markEdited(&object, at: modified)
        return try encode(object)
    }

    /// The same metadata with the favourite star put on or taken off.
    ///
    /// The field is written even into a record that does not carry one, which
    /// is the opposite of what `raiseVersion` and `markMetadataModified` do
    /// below — and for the opposite reason. Those would add a field of ours to
    /// somebody else's document to say something nobody asked about; this
    /// **is** what the user asked for, and a star that is not written is a
    /// star that never appears on the tablet.
    ///
    /// A record that already holds the wanted value comes back byte for byte
    /// as it went in. Not an optimisation but the mechanism by which nothing
    /// is written at all: the index assembled from it hashes the same, so
    /// `commit` finds the root unchanged and leaves it alone. Writing anyway
    /// would raise a version and stamp a new `lastModified` on a document
    /// nothing had changed about.
    public static func favorited(_ data: Data, _ isFavorite: Bool, modified: Date) throws -> Data {
        var object = try decode(data)
        guard object["pinned"] as? Bool != isFavorite else { return data }
        object["pinned"] = isFavorite
        markEdited(&object, at: modified)
        return try encode(object)
    }

    /// The same metadata with the document taken back out of the trash.
    ///
    /// The parent is set to where it goes, and `deleted` is put to `false`
    /// explicitly: a record the tablet marked with the flag rather than with
    /// the parent — both forms exist — would otherwise come back to a folder
    /// and stay invisible on the device.
    public static func restored(_ data: Data, to parent: String?, modified: Date) throws -> Data {
        var object = try decode(data)
        object["parent"] = parent ?? ""
        object["deleted"] = false
        markEdited(&object, at: modified)
        return try encode(object)
    }

    /// The same metadata with the document moved to the trash.
    ///
    /// The trash is a parent, not a flag: `deleted` is left exactly as it was
    /// and `parent` becomes the literal "trash". That is how the tablet does
    /// it, and it is the reason a trashed document can be restored — set
    /// `deleted` instead and the record stops being recoverable.
    public static func movedToTrash(_ data: Data, modified: Date) throws -> Data {
        var object = try decode(data)
        object["parent"] = "trash"
        markEdited(&object, at: modified)
        return try encode(object)
    }

    /// What every edit to the metadata itself does to the record besides the
    /// edit: `version` goes up, `metadatamodified` is set, and `lastModified`
    /// is now.
    ///
    /// Every writer of a document file is expected to raise the version, and
    /// the flag says the change was to the metadata rather than to the pages
    /// — which is why `rewritten`, the one edit that is about the pages, does
    /// not come through here. One function for the five that do, because the
    /// three lines were the same five times over, and a sixth edit that
    /// forgot one of them would have shipped a record the tablet reads
    /// differently.
    private static func markEdited(_ object: inout [String: Any], at modified: Date) {
        raiseVersion(of: &object)
        markMetadataModified(&object)
        object["lastModified"] = milliseconds(modified)
    }

    /// Set `metadatamodified` where the record has it, and only there.
    ///
    /// The same rule as `raiseVersion`, and for the same reason: a notebook made
    /// on current firmware carries neither field, and writing one in would add
    /// ours to somebody else's document. The flag says "what changed was the
    /// metadata, not the pages" — a record that never had it is not asking the
    /// question.
    private static func markMetadataModified(_ object: inout [String: Any]) {
        guard object["metadatamodified"] != nil else { return }
        object["metadatamodified"] = true
    }

    /// Raise `version` where the record has one, and only there.
    ///
    /// A notebook made on current firmware carries ten fields, and `version`
    /// is not among them — nor are `deleted`, `synced` or `metadatamodified`.
    /// Reading the field with a default of nought and writing one back does
    /// not raise a version: it **adds a field of our own to the user's
    /// document**, which is precisely what the rest of this file goes out of
    /// its way not to do. What another client makes of a version it never
    /// wrote is unknown, and an unknown answer about a field somebody may
    /// resolve conflicts by is the worst kind.
    ///
    /// Where the field is there, it is raised, because every writer of a
    /// document file is expected to.
    private static func raiseVersion(of object: inout [String: Any]) {
        guard let version = object["version"] as? Int else { return }
        object["version"] = version + 1
    }

    /// Epoch milliseconds as a string — that is how the tablet writes them. A
    /// number in this field instead of a string is exactly the sort of
    /// difference the other client notices and we do not.
    public static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    private static func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.malformedResponse("metadata is not a JSON object")
        }
        return object
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        // Sorted keys are not cosmetic here: the storage is content-addressed,
        // a dictionary's order is not stable between runs, and without this
        // the same metadata would hash differently every time it was written.
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
