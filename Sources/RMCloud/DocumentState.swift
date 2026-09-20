// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// What a document's metadata means to the library, decoded once behind the
/// wire format.
///
/// This is what crosses the package boundary in `DocumentMetadata`'s place:
/// the wire's own field names (`parent`, `type`, a timestamp as a string of
/// milliseconds) and its `Decodable` conformance stay inside `RMCloud`, and
/// only the fields a caller reasons about leave, already resolved.
public struct DocumentState: Sendable {
    public let visibleName: String
    public let parentID: String?
    public let isFolder: Bool
    public let isTemplate: Bool
    public let isTrashed: Bool
    public let deleted: Bool?
    public let pinned: Bool?
    public let modifiedDate: Date
    public let createdDate: Date?

    /// Decoding a `<uuid>.metadata` file's bytes — the one door out. There is
    /// no public initializer, so a `DocumentState` only ever comes from bytes
    /// the cloud actually sent.
    public static func decode(_ data: Data) throws -> DocumentState {
        let metadata = try JSONDecoder().decode(DocumentMetadata.self, from: data)
        return DocumentState(
            visibleName: metadata.visibleName,
            parentID: metadata.parentID,
            isFolder: metadata.isFolder,
            isTemplate: metadata.isTemplate,
            isTrashed: metadata.isTrashed,
            deleted: metadata.deleted,
            pinned: metadata.pinned,
            modifiedDate: metadata.modifiedDate,
            createdDate: metadata.createdDate
        )
    }
}
