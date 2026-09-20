// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Testing

/// What the transport must never do with an answered request: keep it.
///
/// Traffic is not what these ask about, and cannot be — a test has no server,
/// and the leak was never in one request but in the configuration every one of
/// them ran under. So the configuration is what is asked. On a live account:
/// 20 MB and 686 answered requests in the
/// extension's container, fifteen days old, holding the root index, every
/// document index and the reply that carries the user token.

@Test("A transport nobody configured writes no answers to a cache")
func defaultTransportSessionKeepsNothing() {
    let configuration = URLSessionTransport().session.configuration

    // Falling back to `URLSession.shared` would inherit its cache,
    // `URLCache.shared` — a directory on disk, in the host's container.
    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
}

@Test("The session every download shares keeps nothing either")
func downloadSessionKeepsNothing() {
    let configuration = URLSessionTransport.downloads.configuration

    // Download tasks do not fill `URLCache` — the bodies in the cache
    // top out at 86 KB while hundreds of megabytes go through here — so
    // this session is the one place the rule costs nothing and is asserted
    // rather than relied upon.
    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
}

// The pool is the other half of what sharing that session bought, and the only
// half a configuration can be asked about. A session per download made this
// number describe a limit of one against one; Finder materialises a whole
// selection at once, so that was as many connections to the host as the user
// had selected documents. Nothing else in the file names it.
@Test("Every download together holds a bounded number of connections")
func downloadSessionBoundsItsConnections() {
    #expect(URLSessionTransport.downloads.configuration.httpMaximumConnectionsPerHost == 6)
    #expect(URLSessionTransport.maximumConnectionsPerHost == 6)
}

// The upgrade is an HTTP request, and `URLSession` follows a redirect on it as
// silently as on any other. On `.shared` no delegate watches the hop, so a
// signed storage URL off the origin would be answered with the Bearer token —
// the one path in the package `followRedirect` did not reach.
@Test("The websocket handshake runs on the small requests' session, not on .shared")
func webSocketSessionIsTheRequestsSession() {
    let session = URLSessionWebSocket().session

    #expect(session === URLSessionTransport.requests)
    #expect(session !== URLSession.shared)
    #expect(session.configuration.urlCache == nil)
    #expect(session.delegate is RedirectWatcher)
}

@Test("An upload keeps no cache it was handed")
func uploadConfigurationDropsAnInheritedCache() {
    // An upload builds its session from the transport's configuration, and a
    // transport can be built over a session from outside. `URLSession.shared`
    // is the worst such session there is and the honest thing to hand in: its
    // configuration arrives carrying `URLCache.shared`.
    let inherited = URLSession.shared.configuration
    #expect(inherited.urlCache != nil, "the premise: this is what a cache-bearing configuration looks like")

    let configuration = URLSessionTransport.withoutCache(inherited)

    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
}
