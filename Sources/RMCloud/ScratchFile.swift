// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Scratch files for downloads. One place, so that the names do not spread
/// through the code and so that ownership of the file is obvious: whoever
/// received the URL is the one who cleans up.
///
/// Internal, and a copy. The application this package came out of has one of
/// these for everybody who takes bytes off a network; carrying a dependency on
/// that application's bottom layer for thirty lines, or publishing a second
/// spelling of it from here, would both be worse than the copy.
///
/// Not called `TemporaryFile`, which is what it is called over there and what it
/// was called here at first: two types of that name, one visible through
/// `@testable import`, are ambiguous in any suite that can see both, and the
/// error names the test rather than the cause. `Scratch` is also the better
/// word for it — nothing above this package ever sees one, and what a caller
/// gets is a `URL` it owns.
enum ScratchFile {
    /// A free path in the process temp directory. Does not create a file.
    static func location() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    static func write(_ data: Data) throws -> URL {
        let url = location()
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Take somebody else's temporary file for ourselves. A move is cheaper
    /// than a copy, but is impossible across volumes — there a copy remains,
    /// cleaning up after itself.
    static func claim(_ file: URL) throws -> URL {
        let url = location()
        let manager = FileManager.default
        do {
            try manager.moveItem(at: file, to: url)
        } catch {
            try manager.copyItem(at: file, to: url)
            try? manager.removeItem(at: file)
        }
        return url
    }
}
