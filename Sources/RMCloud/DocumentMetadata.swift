// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The `<uuid>.metadata` file inside a document, as the wire spells it.
///
/// Stays inside this package: `DocumentState.decode` is the one door out,
/// and it hands back the fields a caller needs already resolved — not the
/// wire's own field names, and not this type.
struct DocumentMetadata: Decodable, Sendable {
    let visibleName: String
    let parent: String?
    let type: String
    let deleted: Bool?
    /// The tablet's favourite star. Optional because it is: not every record
    /// carries the field, and an absent flag means "not a favourite" rather
    /// than a metadata file we failed to read.
    let pinned: Bool?
    /// Epoch milliseconds as a string — that is how the tablet writes them.
    let lastModified: String?
    /// The same clock, at the document's birth. Optional twice over: a folder
    /// (`CollectionType`) has no such field at all — nine fields to a
    /// document's ten — and reading it as required would throw away every
    /// folder's metadata.
    let createdTime: String?

    /// The known wire values of `type`. The raw string stays stored: the
    /// protocol is reverse-engineered, an unfamiliar value is possible, and
    /// it is treated as a document — same as before the enum appeared.
    private enum DocumentType: String {
        case collection = "CollectionType"
        case document = "DocumentType"
        case template = "TemplateType"
    }

    var isFolder: Bool { DocumentType(rawValue: type) == .collection }

    /// A page template ("OKR layout", "Weekly planner" and the like). It
    /// arrives in the library on a par with documents but is not a document:
    /// it has no pages, only a `.template` file. It must not be shown in
    /// Finder or counted in the library — the user never created these files.
    var isTemplate: Bool { DocumentType(rawValue: type) == .template }

    /// The trash is a special parent rather than a flag.
    var isTrashed: Bool { parent == "trash" }

    /// An empty parent means the library root.
    var parentID: String? {
        guard let parent, !parent.isEmpty, parent != "trash" else { return nil }
        return parent
    }

    var modifiedDate: Date {
        guard let lastModified, let milliseconds = Double(lastModified) else {
            return .distantPast
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// `nil` rather than a sentinel where the field is absent: Finder's
    /// creation column is better empty than showing 1970 on every folder.
    var createdDate: Date? {
        guard let createdTime, let milliseconds = Double(createdTime) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
