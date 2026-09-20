// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A file read through in pieces, for the two running sums taken over an
/// original: its SHA-256 and its CRC32C.
///
/// One loop rather than one per sum, because the loop is where the two rules
/// that matter live. The file is never in memory whole — an original runs to
/// hundreds of megabytes, and the point of keeping it on disk is lost if
/// measuring it reads it back in. And cancellation is checked at every chunk:
/// the system abandons transfers freely, and grinding through a
/// quarter-gigabyte nobody wants any more is pure wasted I/O. Two copies of
/// that loop were two places for either rule to quietly stop being true.
///
/// The chunk size is the caller's, and the two callers name different ones on
/// purpose — see `CRC32C.chunkSize` for why.
enum FileChunks {
    /// Hand every chunk of `file` to `body`, in order, until the end.
    static func forEach(in file: URL, ofSize size: Int, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        while let chunk = try handle.read(upToCount: size), !chunk.isEmpty {
            try Task.checkCancellation()
            try body(chunk)
        }
    }
}
