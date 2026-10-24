// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RMCloud
import Testing

#if canImport(Darwin)
// Only Apple's URLProtocol can deliver a non-HTTP URLResponse to an HTTP request.
// The socket server separately verifies that invalid HTTP bytes are refused on every platform.
@Test("A reply that is not HTTP is refused rather than cast away")
func aReplyThatIsNotHTTPIsRefused() async throws {
    let url = URL.constant("https://non-http.invalid/reply")
    let session = NonHTTPResponseProtocol.session()
    defer { session.finishTasksAndInvalidate() }

    let error = await #expect(throws: CloudError.self) {
        _ = try await URLSessionTransport(session: session).send(URLRequest(url: url))
    }
    guard case .malformedResponse = error else {
        Issue.record("a reply with no status came back as \(String(describing: error))")
        return
    }
}

@Test("A download whose reply is not HTTP is refused")
func aDownloadWhoseReplyIsNotHTTPIsRefused() async {
    let url = URL.constant("https://non-http.invalid/reply")
    let router = DownloadRouter()
    let session = NonHTTPResponseProtocol.session(delegate: router)
    defer { session.finishTasksAndInvalidate() }

    let error = await #expect(throws: CloudError.self) {
        _ = try await router.run(
            URLRequest(url: url),
            ceiling: DownloadCeiling(limitBytes: .max),
            onProgress: { _, _ in },
            in: session
        )
    }
    guard case .malformedResponse = error else {
        Issue.record("a download with no status came back as \(String(describing: error))")
        return
    }
}

private final class NonHTTPResponseProtocol: URLProtocol {
    static func session(delegate: (any URLSessionDelegate)? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonHTTPResponseProtocol.self]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
