// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Reading a JWT payload without verifying the signature.
///
/// The user token arrives from the auth server over TLS, and its claims are
/// read only for display and plan detection — nothing here grants access by
/// itself, so skipping verification is safe. One implementation on purpose:
/// token handling is exactly the place where a second copy would drift
/// unaudited.
///
/// That safety is a boundary, not a precedent: a claim that steers anything
/// — the way the region claim becomes a host only through an allowlist —
/// must earn its own guard, never ride this shortcut.
public enum JWT {
    /// The decoded payload — the middle of the three dot-separated parts.
    /// `nil` when the string is not a JWT or its base64url does not decode.
    public static func payload(of token: String) -> Data? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        // base64url without padding — as in every JWT.
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    /// The payload as a claims dictionary; `nil` when it is not a JSON object.
    public static func claims(of token: String) -> [String: Any]? {
        guard let payload = payload(of: token) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
}
