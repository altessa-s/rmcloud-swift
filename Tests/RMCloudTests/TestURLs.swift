// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A URL written into a test rather than received from anywhere.
///
/// The package has one of these too, file-private beside the three literals that
/// need it. Not shared with the tests on purpose: a helper visible across a module
/// boundary is a helper that collides with the host's own, and the error names a
/// test rather than the cause. A forced unwrap here instead would end the whole
/// run with a signal, leaving the case that failed the one thing the output does
/// not name.
extension URL {
    static func constant(
        _ text: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> URL {
        guard let url = URL(string: text) else {
            preconditionFailure("not a URL: \(text)", file: file, line: line)
        }
        return url
    }
}
