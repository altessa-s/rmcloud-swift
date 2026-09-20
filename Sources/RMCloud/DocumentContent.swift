// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The slice of `<uuid>.content` this client reads, as the wire spells it.
///
/// The file carries far more — page lists, zoom, orientation, the template
/// per page — and the renderer reads those through its own door. Here only
/// what the library index keeps: the document's tags. Everything is
/// optional, because a folder's `.content` is often `{}` and an old
/// notebook's has no `tags` key at all.
struct DocumentContent: Decodable, Sendable {
    struct Tag: Decodable, Sendable {
        let name: String
    }

    /// Tags of the document as a whole. `pageTags` — the same shape plus a
    /// `pageId` — are a page's, and stay unread: the index is about
    /// documents.
    let tags: [Tag]?
}
