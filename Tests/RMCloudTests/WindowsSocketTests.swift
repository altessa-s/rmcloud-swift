// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

#if os(Windows)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import RMCloud

// This platform has no `URLSessionWebSocketTask`, and the NIO socket needs a
// TLS stack that does not build here — so the absence is named where the
// attempt is made, and named as something not worth retrying.
@Test("The notification socket is named as unsupported on this platform")
func theNotificationSocketIsUnsupported() async {
    let error = await #expect(throws: CloudError.self) {
        _ = try await URLSessionWebSocket().connect(
            to: URLRequest(url: URL(string: "wss://example.invalid/notifications")!)
        )
    }
    guard case .unsupportedOnThisPlatform = error else {
        Issue.record("a missing socket came back as \(String(describing: error))")
        return
    }
}
#endif
