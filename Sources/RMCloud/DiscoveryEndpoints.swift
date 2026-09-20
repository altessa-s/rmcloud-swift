// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// What `GET {sync}/discovery/v1/endpoints` says, and — more to the point —
/// what may be believed of it.
///
/// A real account gets back no `Authorization`, `Cache-Control: public,
/// max-age=3600`, and the very same bytes from both hosts down to the `Etag`,
/// served out of storage with a `Last-Modified` years old. So this is a public
/// static file, one for everybody, not an answer about an account. Two things
/// follow, and both are the reason this type exists rather than a plain
/// decode:
///
/// - **The account's region is not in here.** It is in the token's `tectonic`
///   claim. A file that is the same for every account cannot
///   name the region of one, and ours agreeing with the claim is a
///   coincidence of being in `eu`.
/// - **The sync host is not in here either.** The answer has exactly three
///   fields — `notifications`, `webapp`, `mqttbroker` — and where the root
///   lives is not among them.
///
/// What is worth having is the first: the socket's host. `webapp` is kept for
/// comparison only (see `EndpointResolver`), and `mqttbroker` is dropped on
/// the floor — this client does not speak MQTT, and a value nobody uses is a
/// value nobody has to trust.
struct DiscoveryEndpoints: Sendable, Equatable {
    /// The push channel's host, when the service named one we are willing to
    /// go to.
    let notifications: URL?
    /// Where the service says tokens are redeemed. Never followed by itself —
    /// held so that a difference from the host we ship can be noticed.
    let webapp: URL?

    /// The answer, parsed and filtered. `nil` when the body is not the JSON
    /// object of bare hostnames this path answers with — which is what a
    /// captive portal's 200 looks like from here.
    static func parse(_ data: Data) -> DiscoveryEndpoints? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: String]
        else { return nil }
        return DiscoveryEndpoints(
            notifications: fields["notifications"].flatMap(CloudEndpoints.trustedHost(named:)),
            webapp: fields["webapp"].flatMap(CloudEndpoints.trustedHost(named:))
        )
    }

    /// Ask the service, and take nothing on faith.
    ///
    /// Unauthenticated because the path wants no token — and sending one to a
    /// file the CDN hands to anybody would be a gift. Nothing waits on the
    /// answer, so it does not get to hold anything up: a short fuse, and any
    /// failure at all reads as "no answer", which every caller here already
    /// has a working fallback for.
    ///
    /// Free of the resolver's cache on purpose: the token provider asks this
    /// at most once in the life of a process, when the host it was built with
    /// turned out not to exist, and giving it a share of an actor's state to
    /// reach that would be a lock around a single request.
    static func fetch(
        from endpoints: CloudEndpoints,
        using transport: any HTTPTransporting
    ) async -> DiscoveryEndpoints? {
        var request = ProtocolRequest.to(endpoints.discovery)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await transport.send(request),
              response.statusCode == 200
        else { return nil }
        return parse(data)
    }

    /// What the answer says of itself: `Cache-Control: public, max-age=3600`.
    static let lifetime: TimeInterval = 3600
    /// Nothing waits on this, so it does not get to hold anything up.
    private static let timeout: TimeInterval = 3

    /// The socket host, but only if it belongs to the account we hold a token
    /// for.
    ///
    /// The cross-check is the whole point of routing by this file at all. The
    /// JSON is one object for everybody and it names `eu`; an account whose
    /// claim says otherwise would be sent — with its Bearer token — to another
    /// region's host on the word of a file that never heard of it. So the
    /// value is taken only when it is the region's own host, or the sync host
    /// we are already talking to.
    func notificationsHost(region: String?, sync: URL) -> URL? {
        guard let notifications, let host = notifications.host() else { return nil }
        if host == sync.host() { return notifications }
        guard let region, host.hasPrefix("\(region.lowercased()).") else { return nil }
        return notifications
    }
}
