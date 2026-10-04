// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog

/// The only place the protocol's hosts and paths live in.
///
/// The values are checked against `config/url.go` in `ddvk/rmapi`. The
/// protocol is unofficial: new paths are added here only after being verified
/// on a live account through `rmctl`.
public struct CloudEndpoints: Sendable, Equatable {
    public var authHost: URL
    public var syncHost: URL

    public init(authHost: URL, syncHost: URL) {
        self.authHost = authHost
        self.syncHost = syncHost
    }

    public static let production = CloudEndpoints(
        authHost: URL.constant("https://webapp-prod.cloud.remarkable.engineering"),
        syncHost: URL.constant("https://internal.cloud.remarkable.com")
    )

    /// Overriding the hosts for debugging and for tests against a fake
    /// server. The counterpart of rmapi's `RMAPI_AUTH` / `RMAPI_HOST`.
    ///
    /// ```
    /// RMCLOUD_HOST         both hosts at once
    /// RMCLOUD_AUTH_HOST    where tokens are redeemed
    /// RMCLOUD_SYNC_HOST    where the root, the indexes and the blobs live
    /// ```
    ///
    /// **Not for a shipped app.** Whoever picks the host receives the device
    /// token and the user token, because the client carries them there itself
    /// — and an environment variable is picked by whoever last ran
    /// `launchctl setenv`, not by whoever signed the bundle. A signed app
    /// holding a Keychain entitlement, pointed at somebody else's host, is a
    /// deputy carrying credentials it alone is allowed to hold. So the host
    /// application calls this only in a debug build; the release build takes
    /// `production` and reads no variables at all.
    ///
    /// `rmctl` is the other caller, and there it is the whole point: the tool
    /// exists to talk to whatever is being debugged.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CloudEndpoints {
        var endpoints = production
        if let all = override(environment["RMCLOUD_HOST"]) {
            endpoints.authHost = all
            endpoints.syncHost = all
        }
        if let auth = override(environment["RMCLOUD_AUTH_HOST"]) {
            endpoints.authHost = auth
        }
        if let sync = override(environment["RMCLOUD_SYNC_HOST"]) {
            endpoints.syncHost = sync
        }
        return endpoints
    }

    /// An override, taken only when it names somewhere a token may go.
    ///
    /// HTTPS anywhere, plain HTTP on the loopback, and nowhere else. The
    /// loopback is where a fake server lives and nothing sent there leaves the
    /// machine; plain HTTP anywhere else hands the tokens to whoever is on the
    /// way. App Transport Security already refuses such a connection inside
    /// the app, so there the variable was a silent failure rather than a
    /// downgrade — but `rmctl` has no Info.plist and no ATS, and it would have
    /// made the connection.
    private static func override(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased()
        else {
            Log.cloud.error("ignoring a host override that is not a URL")
            return nil
        }
        let loopback = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || (scheme == "http" && loopback.contains(host)) else {
            Log.cloud.error(
                "ignoring host override \(host, .public): only HTTPS, or HTTP on the loopback"
            )
            return nil
        }
        return url
    }

    // MARK: - Paths

    /// Exchanging a one-time code for a device token.
    public var newDeviceToken: URL { authHost.appending(path: "token/json/2/device/new") }

    /// Exchanging a device token for a short-lived user token.
    public var newUserToken: URL { authHost.appending(path: "token/json/2/user/new") }

    /// Taking this device off the account: the device token stops being one.
    public var deleteDeviceToken: URL { authHost.appending(path: "token/json/3/device/delete") }

    /// The root of the tree, read. The current path is v4 — where the official
    /// desktop reads and where a body carries the whole of what the pointer
    /// says — and v3 is the fallback for an account that answers only there.
    public func root(_ version: RootVersion) -> URL {
        switch version {
        case .v3: syncHost.appending(path: "sync/v3/root")
        case .v4: syncHost.appending(path: "sync/v4/root")
        }
    }

    /// The root of the tree, written. **Always v3**, whichever path answered
    /// the read.
    ///
    /// The two need not agree, and on the official client they do not: on an
    /// account whose region is named in the token it reads `/sync/v4/root` and
    /// writes `/sync/v3/root`. A PUT on v4 has never been seen on the wire —
    /// not by us, not in a dump — so a client that wrote wherever it had read
    /// would be sending, on some accounts, a request whose reply nobody has
    /// ever observed.
    public var rootWrite: URL { root(.v3) }

    /// A blob by its SHA-256.
    public func blob(hash: String) -> URL {
        syncHost.appending(path: "sync/v3/files/\(hash)")
    }

    /// The hosts the service names for itself. Answered without a token, and
    /// cached by the CDN — see `DiscoveryEndpoints` for what may be believed
    /// of it.
    public var discovery: URL { syncHost.appending(path: "discovery/v1/endpoints") }

    /// The sync host of an account in `region`, as the token's `tectonic`
    /// claim names it. `nil` for anything that is not a plain regional
    /// label: the value ends up in a hostname this client carries a Bearer
    /// token to, so a claim that does not look like a region is not made into
    /// one.
    public static func tectonic(region: String) -> URL? {
        let label = region.lowercased()
        guard (2...8).contains(label.count), label.allSatisfy({ $0.isLetter && $0.isASCII }) else {
            return nil
        }
        return URL(string: "https://\(label).tectonic.remarkable.com")
    }

    /// A bare hostname from a server's answer, turned into somewhere a token
    /// may be sent — or refused.
    ///
    /// Discovery answers with bare hosts (`eu.tectonic.remarkable.com`), so
    /// the scheme is ours to add and never theirs to choose. What comes back
    /// is checked rather than trusted: the JSON is public, unauthenticated and
    /// served from storage, and a captive portal answers 200 with HTML for any
    /// address at all. Only reMarkable's own two domains are accepted.
    public static func trustedHost(named value: String) -> URL? {
        let name = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, name.count <= 253,
              !name.contains("/"), !name.contains(":"), !name.contains("@"),
              name.allSatisfy({ $0.isLetter && $0.isASCII || $0.isNumber || $0 == "." || $0 == "-" }),
              Self.trustedDomains.contains(where: { name.hasSuffix($0) }),
              let url = URL(string: "https://\(name)"), url.host() == name
        else { return nil }
        return url
    }

    /// Whose hosts we are willing to be pointed at.
    private static let trustedDomains = [".remarkable.com", ".remarkable.engineering"]

    /// The notification websocket: the server pushes "SyncComplete" when
    /// another client finishes writing the root — the `broadcast` flag of
    /// the root PUT is exactly this channel. The path is verified against
    /// rmfakecloud (`/notifications/ws/json/1`, Bearer user token); the
    /// legacy generation reached it through a discovery service, the
    /// current one serves it from the sync host.
    public var notifications: URL {
        Self.notifications(on: syncHost)
    }

    /// The same socket on a host somebody else named — discovery calls this
    /// one `notifications`, and on our account it was the sync host itself.
    /// The path is the same wherever it is served from.
    public static func notifications(on host: URL) -> URL {
        host.appending(path: "notifications/ws/json/1")
    }

    /// The page where the user reads a one-time code. Not a protocol host:
    /// it is the website the onboarding button opens.
    public static let connectPage = URL.constant("https://my.remarkable.com/device/desktop/connect")

    /// Frozen, for the reason given on `CloudError`.
    @frozen
    public enum RootVersion: Sendable, CaseIterable {
        case v3
        case v4
    }
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness
// the compiler derives — and that witness is internal, so it is absent from
// this module's symbol table when RMCloud is linked as a binary framework.
// The reference resolves in a release build, where the comparison is inlined,
// and fails to link in a debug one. Declaring `==` here puts the comparison
// behind an exported symbol, which costs nothing and keeps `@frozen`: a new
// case must still break a consumer's build rather than fall into an
// `@unknown default`.
extension CloudEndpoints.RootVersion {
    public static func == (lhs: CloudEndpoints.RootVersion, rhs: CloudEndpoints.RootVersion) -> Bool {
        switch (lhs, rhs) {
        case (.v3, .v3), (.v4, .v4): true
        default: false
        }
    }
}

/// A URL decided when the code was written: this protocol's hosts, and the page
/// a person is sent to in order to connect a device.
///
/// `URL(string:)` is failable because most of what it is handed comes from
/// outside, and there the absence of a value is an answer to carry. A literal
/// spelled ten lines above is not: if it stops parsing, that is a typo in this
/// package, and it has to break the tests rather than reach a person's click as a
/// button that does nothing. A named function rather than `!` at each site, so
/// that the force-unwrap can be forbidden everywhere else.
///
/// File-private, and a copy of one the application above also has. Shared, the
/// two collide in any module that can see both — which a test with
/// `@testable import RMCloud` can — and there is no reason for a spelling this
/// small to be visible past the three literals that use it.
private extension URL {
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
