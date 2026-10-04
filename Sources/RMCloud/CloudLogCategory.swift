// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import RedactLog

/// The channel this package writes on.
///
/// Named here because a category is a label `RedactLog` does not own: what the parts
/// of a process are is a fact about the process, and a package that logs is one
/// of those parts. It used to be declared with an application's other ten, which
/// is exactly what it could not keep being if the protocol was to be reusable.
///
/// The raw value is a contract with whoever reads a log:
/// `log stream --predicate 'category == "cloud"'` is written down in notes that
/// predate this file. Spelled out for that reason.
public extension LogCategory {
    static let cloud = LogCategory(rawValue: "cloud")
}

/// Sugar, and the reason every line in this package still reads
/// `Log.cloud.debug(…)` after the categories stopped being an enum.
public extension Log {
    static var cloud: LogChannel { logger(.cloud) }
}
