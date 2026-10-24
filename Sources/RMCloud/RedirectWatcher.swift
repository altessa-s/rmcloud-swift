// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// The one thing the small requests need a delegate for: meeting a redirect.
///
/// `URLSession` follows one silently, so without this a hop is invisible — and
/// this protocol is known to answer a blob with a signed storage URL. What the
/// hop is allowed to carry is decided in `followRedirect`, which is where all
/// three of this package's delegates send it.
///
/// Internal rather than private so that a test can hand it a session of its own
/// with a server under it: the rule about the token is only worth having if it
/// is reached, and nothing above this delegate can see whether it was.
final class RedirectWatcher: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirect(response, to: request, on: task))
    }
}
