// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// What a `.content` file says about the document as a whole, resolved
/// and handed out — the counterpart of `DocumentState` for the other
/// metadata file.
public struct DocumentContentState: Sendable, Hashable {
    /// The document's tags, in the file's order, each once. The tablet
    /// writes a tag as a name and a timestamp; only the name is a fact
    /// about the document.
    public let tags: [String]

    /// The one door out of a `.content` file's bytes. There is no public
    /// initializer: a `DocumentContentState` only ever comes from bytes the
    /// cloud sent, like its sibling.
    public static func decode(_ data: Data) throws -> DocumentContentState {
        let content = try JSONDecoder().decode(DocumentContent.self, from: data)
        var seen: Set<String> = []
        let tags = (content.tags ?? [])
            .map(\.name)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return DocumentContentState(tags: tags)
    }
}
