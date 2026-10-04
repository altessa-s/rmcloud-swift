// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

public extension DocumentIndex {
    /// The index as fetched, parsed and held to its address.
    ///
    /// Two hashes are accepted for one index, because the service has used
    /// both: the hash of the bytes as they were sent, and the hash of the
    /// entries the bytes list. Which one a document carries follows the
    /// account's history, not anything a client can know beforehand, so the
    /// bytes are judged against the file hash first and against the node
    /// hash then. Substituted or corrupted bytes match neither, because both
    /// are computed from the bytes in hand. Here, beside the format, rather
    /// than in the client: a cache that hands the same bytes back has to
    /// hold them to the same address.
    static func decode(_ data: Data, addressedBy hash: String, name: String) throws -> DocumentIndex {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw CloudError.malformedIndex(line: "", reason: "index is not UTF-8")
        }
        let fileHash = ContentHash.blob(data)
        let index = try IndexParser.parse(text)
        guard fileHash != hash else { return index }
        guard (try? ContentHash.node(of: index.entries)) == hash else {
            throw CloudError.hashMismatch(expected: hash, actual: fileHash)
        }
        Log.cloud.debug("index \(name, .public) is addressed by its node hash")
        return index
    }
}
