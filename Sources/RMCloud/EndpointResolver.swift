// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// Where this client talks to, decided in one place.
///
/// The hosts of this protocol are not one address. The root, the indexes and
/// the blobs live on the account's own region host — `{region}.tectonic…` —
/// and the region is named by the user token's `tectonic` claim and by nothing
/// else. The push socket is served from a host the service publishes under
/// `discovery/v1/endpoints`. Tokens are redeemed on a third, which is ours and
/// stays ours (see below). `CloudEndpoints` remains the value that spells the
/// paths; this actor is what decides which host they hang off, so that no
/// caller has to.
///
/// The order is deliberate, and it is an order of trust rather than of
/// convenience:
///
/// 1. **The static configuration works on its own.** `internal` answers the
///    root on both paths, the blobs and `check-files`. Nothing below is
///    required for the product to run, which is what lets every step of it
///    fail quietly.
/// 2. **The region comes from the token**, because that is the only source
///    tied to the account, and it costs no request at all.
/// 3. **Discovery is asked once**, without a token, on the host from step 2 —
///    and only the socket's host is taken from it, only after it is checked
///    against the region we already know.
///
/// A pinned resolver — a test's fake server, an `RMCLOUD_SYNC_HOST` override —
/// does none of this. Whoever names a host that way has said where this client
/// goes, and a resolver that then quietly asked a public file where to go
/// instead would carry the token somewhere they did not name.
public actor EndpointResolver {
    /// What the process was built with: production, or an override.
    private let configured: CloudEndpoints
    /// Whether that naming is final. An override is a decision, not a default.
    private let pinned: Bool
    private let transport: any HTTPTransporting
    private let tokens: TokenProvider?
    private let now: @Sendable () -> Date

    /// The region, remembered against the token it was read from: a token is
    /// bought afresh every few hours, and re-parsing one we have already read
    /// on every request would be a base64 decode per blob.
    private var regionOfToken: (token: String, region: String?)?
    /// The last discovery attempt, successful or not. A failure is cached too:
    /// the fallback it leaves behind is a host that works, and asking again
    /// per request would spend a round trip to learn the same thing.
    private var attempt: (at: Date, answer: DiscoveryEndpoints?)?
    /// Whether the region host has been given up on for this process.
    private var demoted = false
    /// Whether the difference between our auth host and the published one has
    /// already been said out loud. Once is a notice; every hour is noise.
    private var reportedAuthDrift = false

    public init(
        configured: CloudEndpoints = .production,
        pinned: Bool = false,
        transport: any HTTPTransporting = URLSessionTransport(),
        tokens: TokenProvider?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configured = configured
        self.pinned = pinned
        self.transport = transport
        self.tokens = tokens
        self.now = now
    }

    /// A resolver that resolves nothing: the hosts are the ones given.
    ///
    /// For the tests and for `rmctl` against a fake server — and it is the
    /// same guarantee the override has in a debug build, spelled as a
    /// constructor so that a caller cannot half-mean it.
    public static func pinned(to endpoints: CloudEndpoints) -> EndpointResolver {
        EndpointResolver(configured: endpoints, pinned: true, tokens: nil)
    }

    /// Where the sync requests go, and where tokens are redeemed.
    ///
    /// Never throws and never blocks on the network: the worst case is the
    /// configuration it was built with, which is a working account's worth of
    /// service on its own.
    public func endpoints() async -> CloudEndpoints {
        guard !pinned, !demoted, let region = await region() else { return configured }
        guard let host = CloudEndpoints.tectonic(region: region) else { return configured }
        var resolved = configured
        resolved.syncHost = host
        return resolved
    }

    /// Where the push socket is opened.
    ///
    /// Discovery's one useful field, and only when it survives the region
    /// cross-check in `DiscoveryEndpoints`. Otherwise the sync host, which is
    /// where the socket is served from anyway on this account.
    public func notificationsHost() async -> URL {
        let endpoints = await endpoints()
        guard !pinned else { return endpoints.notifications }
        let answer = await discovery(from: endpoints)
        let host = answer?.notificationsHost(region: await region(), sync: endpoints.syncHost)
        return host.map(CloudEndpoints.notifications(on:)) ?? endpoints.notifications
    }

    /// Give up on the region host for the rest of this process.
    ///
    /// Called when a request did not reach it at all — no DNS, no connection.
    /// The static host serves every account, so falling back to it costs
    /// nothing but the region's proximity, whereas staying on a host that is
    /// not there costs the library. One way only: a process that has fallen
    /// back does not creep forward again on the next request, because the
    /// failure it is avoiding looks exactly like the network being away.
    public func syncHostFailed() {
        guard !pinned, !demoted else { return }
        demoted = true
        Log.cloud.notice("the region host did not answer; falling back to the configured sync host")
    }

    // MARK: - The two sources

    /// The account's region, from the claim of the token we already hold.
    ///
    /// `try?` throughout, and on purpose: this is asked on the way to a
    /// request that is about to fetch the very same token and report its own
    /// failure properly. A resolver that threw would turn "not registered
    /// yet" into "cannot decide where to go".
    private func region() async -> String? {
        guard let tokens, let token = try? await tokens.userToken() else { return nil }
        if let regionOfToken, regionOfToken.token == token { return regionOfToken.region }
        let region = (JWT.claims(of: token)?["tectonic"] as? String)
            .flatMap { CloudEndpoints.tectonic(region: $0) != nil ? $0.lowercased() : nil }
        regionOfToken = (token, region)
        return region
    }

    /// The published hosts, asked at most once an hour.
    ///
    /// Unauthenticated, because the path wants no token; short-fused, because
    /// nothing waits on the answer — a socket that opens on the sync host is
    /// not a degraded socket.
    private func discovery(from endpoints: CloudEndpoints) async -> DiscoveryEndpoints? {
        if let attempt, now().timeIntervalSince(attempt.at) < DiscoveryEndpoints.lifetime {
            return attempt.answer
        }
        let answer = await DiscoveryEndpoints.fetch(from: endpoints, using: transport)
        attempt = (now(), answer)
        if let answer { noticeAuthDrift(answer) }
        return answer
    }

    /// The tripwire on the auth host.
    ///
    /// `webapp` is the host where a one-time code becomes a device token, and
    /// the published value is the one we ship. It is not followed: that
    /// exchange is the highest-consequence request this client makes, and its
    /// address is not taken from a public, unauthenticated file. But a
    /// difference means reMarkable has moved it, and knowing that from a log
    /// beats learning it from an onboarding that stopped working.
    private func noticeAuthDrift(_ answer: DiscoveryEndpoints) {
        guard !reportedAuthDrift, let published = answer.webapp?.host(),
              published != configured.authHost.host()
        else { return }
        reportedAuthDrift = true
        Log.cloud.notice(
            "discovery publishes a different auth host: \(published, .public)"
        )
    }
}
