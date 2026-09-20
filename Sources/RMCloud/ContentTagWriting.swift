// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Writing the `tags` of `<uuid>.content` — the one field of that file this
/// client ever changes.
///
/// The edit works on the raw JSON object for the reason `MetadataWriting`
/// does, and more so: a `.content` carries the page list, the zoom, the
/// reader's settings and whatever the next firmware adds, while
/// `DocumentContent` reads one key of it. Re-encoding the read model would
/// drop the user's document and keep its labels.
///
/// A round trip through `JSONSerialization` was measured on a live
/// notebook's `.content` — `cPages`, the zoom doubles, the millisecond
/// stamps — and left every value and every type where it stood. What it does
/// not preserve is the file's own layout: the tablet writes four spaces and
/// its own key order, and what comes back is compact and sorted. That costs
/// nothing, because the tablet reads JSON rather than bytes, and it is why
/// this is safe to do at all.
public enum ContentTagWriting {
    /// The same `.content` with the document's tags replaced by `names`, in
    /// that order.
    ///
    /// A name the file already carries keeps its own `timestamp`: the tablet
    /// stamps a tag when it is put on, and re-stamping one that was merely
    /// listed again would move a date nobody touched. The stamp is a number
    /// here, unlike the strings `.metadata` counts in.
    ///
    /// `pageTags` are left alone. They are a page's mark and this Mac has no
    /// business with them — the same line `DocumentContentState` draws when
    /// reading.
    ///
    /// Tags that already read exactly like this come back byte for byte as
    /// they went in, and for the reason spelled out on
    /// `MetadataWriting.favorited`: the entry hashes the same, the commit
    /// finds the root unchanged, and nothing is written at all.
    public static func tagged(_ data: Data, _ names: [String], now: Date) throws -> Data {
        var object = try decode(data)
        let existing = (object["tags"] as? [[String: Any]]) ?? []
        guard existing.compactMap({ $0["name"] as? String }) != names else { return data }

        var stamps: [String: Any] = [:]
        for tag in existing {
            guard let name = tag["name"] as? String, let stamp = tag["timestamp"] else { continue }
            stamps[name] = stamp
        }
        object["tags"] = names.map { name in
            ["name": name, "timestamp": stamps[name] ?? milliseconds(now)]
        }
        return try encode(object)
    }

    /// The `.content` of a document written again, carrying the tags the
    /// record already had.
    ///
    /// A re-send rebuilds this file from the document on disk, and that file
    /// knows nothing of tags: they are the tablet's record of what the user
    /// called the document, not a property of its pages. Rewriting without
    /// them loses a fact the user put there, for no reason they would
    /// recognise — the pages changed, the label did not.
    ///
    /// The old entries are carried across whole, stamps and all, so a
    /// re-send moves no date the user did not touch. `adding` is what every
    /// send puts on, appended where it is not there already.
    public static func carryingTags(from old: Data, into new: Data, adding names: [String], now: Date) throws -> Data {
        var object = try decode(new)
        let kept = (try? decode(old)["tags"] as? [[String: Any]]) ?? []
        let known = Set(kept.compactMap { $0["name"] as? String })
        object["tags"] = kept + names.filter { !known.contains($0) }.map {
            ["name": $0, "timestamp": milliseconds(now)]
        }
        return try encode(object)
    }

    /// The stamp a tag put on now would carry. A number, as the tablet's own
    /// records have it. Public because a document written from scratch carries
    /// tags too, and one spelling of the stamp is enough.
    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.malformedResponse("content is not a JSON object")
        }
        return object
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        // Sorted for the reason `MetadataWriting` sorts: the storage is
        // content-addressed, and a dictionary's order is not stable between
        // runs.
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
