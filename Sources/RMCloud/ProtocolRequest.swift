// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Where every request this client sends is born.
///
/// One place, because the thing it settles cannot be checked by reading any
/// single caller: whether the service answers us at all. The name is not
/// decoration — the service reads it and turns some values away outright, a
/// browser's `Mozilla/5.0` among them — and a client whose name does not parse
/// is one whose traffic can be sorted out of the flow at any time. Nothing
/// about this protocol is under our control.
///
/// Three call sites spelling the same lines by hand, with nothing keeping
/// them in agreement, is exactly what a single place avoids. A caller asks
/// for a request rather than building one, and what it gets already knows
/// who is asking.
public enum ProtocolRequest {
    /// A request that already names this client. Everything else — the token,
    /// `rm-filename`, a body — the caller adds, because those differ per call
    /// and this does not.
    public static func to(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        return request
    }

    /// The name itself: `desktop/<version> (macos <version>)`, the shape the
    /// reMarkable desktop sends and the service is known to accept.
    ///
    /// Public so that a test can hold it against what went out on the wire.
    public static let userAgent = "desktop/\(desktopVersion) (macos \(systemVersion))"

    /// The desktop generation whose traffic this client matches.
    ///
    /// Deliberately not this package's own version: that number names our
    /// code, while this field names the protocol dialect being spoken. It moves when
    /// the protocol is re-checked against a newer desktop, not when this
    /// project ships.
    static let desktopVersion = "3.28.0"

    /// The running system, as macOS itself spells it: `26.1`, or `26.1.2` when
    /// there is a patch. `operatingSystemVersionString` is no use here — it
    /// answers "Version 26.1 (Build 25B78)", which is a sentence rather than a
    /// version.
    static var systemVersion: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let head = "\(system.majorVersion).\(system.minorVersion)"
        return system.patchVersion == 0 ? head : "\(head).\(system.patchVersion)"
    }
}
