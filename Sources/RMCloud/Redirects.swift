// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RedactLog

/// What happens to a redirect before this client follows it.
///
/// `URLSession` follows one on its own and only shows the delegate the request
/// it is about to send. One header must not go with it: the user token. A blob
/// request is answered by storage, and storage is entitled to hand back a
/// signed URL on a host that is not reMarkable's — at which point a `Bearer`
/// for the reMarkable cloud would be presented to whoever answers there. The
/// token is the credential this whole package exists to keep in one place, and
/// a redirect is the one route by which it can leave without anybody choosing
/// to send it.
///
/// So: the header is dropped the moment the hop changes scheme, host or port,
/// and kept when it does not — a request that redirects inside its own origin
/// is still the same conversation, and stripping it there would turn an
/// ordinary hop into a 401.
///
/// A rule apart from the delegates that apply it, because the delegates need a
/// live `URLSession` and a server to reach at all, and this is the half where a
/// mistake is a leaked token rather than a wrong answer.
enum Redirects {
    /// The header in question, spelled the way this package sets it.
    static let authorization = "Authorization"

    /// The redirect as it may be sent: the request the loading system built,
    /// minus the token when the hop leaves the origin it started from.
    ///
    /// `previous` is where the redirecting answer came from. `nil` means the
    /// response named no URL of its own, which is not a state this protocol
    /// produces — and an origin nobody can name is not one we can call the
    /// same, so the token comes off.
    static func following(_ redirect: URLRequest, from previous: URL?) -> URLRequest {
        guard redirect.value(forHTTPHeaderField: authorization) != nil else { return redirect }
        guard sameOrigin(previous, redirect.url) else {
            var stripped = redirect
            stripped.setValue(nil, forHTTPHeaderField: authorization)
            return stripped
        }
        return redirect
    }

    /// The redirect as it may be sent once the loading system has had its say.
    ///
    /// The loading system builds the redirect request itself, so a delegate is
    /// handed one whose `Authorization` is already gone. "Kept inside the
    /// origin" therefore has to mean put back, not left alone — and *which*
    /// origin is the one the task started from, never the hop before it. A
    /// chain is what tells the two apart: a second hop that stays on the host
    /// the first hop was sent to is same-origin with the hop before it, and
    /// still not ours.
    static func carryingToken(
        _ following: URLRequest,
        startedAt original: URL?,
        token: String?
    ) -> URLRequest {
        guard sameOrigin(original, following.url),
              following.value(forHTTPHeaderField: authorization) == nil,
              let token
        else { return following }
        var restored = following
        restored.setValue(token, forHTTPHeaderField: authorization)
        return restored
    }

    /// One hop, as every delegate in this package takes it: the rule about the
    /// origin first, then the token put back where it belongs.
    ///
    /// A function of its own, and not three lines inside `followRedirect`,
    /// because the wiring is the half that leaks: a rule that compares against
    /// `previous` is wrong however right `carryingToken` is, and only a test
    /// that drives a real chain can tell the two apart.
    static func followed(
        _ redirect: URLRequest,
        from previous: URL?,
        startedAt original: URLRequest?
    ) -> URLRequest {
        carryingToken(
            following(redirect, from: previous),
            startedAt: original?.url,
            token: original?.value(forHTTPHeaderField: authorization)
        )
    }

    /// Whether two URLs are the same origin: scheme, host and port, with the
    /// scheme's default port standing in for one nobody wrote down — so that
    /// `https://host` and `https://host:443` are not told apart.
    ///
    /// Case is folded on the scheme and the host because neither is
    /// case-sensitive, and a redirect that only changes the spelling of a
    /// hostname is not a redirect to somewhere else.
    static func sameOrigin(_ one: URL?, _ other: URL?) -> Bool {
        guard let one, let other,
              let scheme = one.scheme?.lowercased(),
              let otherScheme = other.scheme?.lowercased(),
              let host = one.host()?.lowercased(),
              let otherHost = other.host()?.lowercased()
        else { return false }
        return scheme == otherScheme && host == otherHost && port(of: one) == port(of: other)
    }

    /// The port a URL is really on: the one it names, or the one its scheme
    /// implies. `nil` for a scheme with no default — and that answers `nil` on
    /// both sides only when the schemes match, which is checked first.
    private static func port(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// The whole of what every delegate in this package does with a redirect: write
/// it down, take the token off it when it leaves the origin, and let it go.
///
/// One function because there are three delegates — the small requests, the
/// downloads and the uploads — and each of them followed redirects by handing
/// the request straight back. Three copies of a rule about credentials is three
/// places for it to stop being true.
func followRedirect(
    _ response: HTTPURLResponse,
    to request: URLRequest,
    on task: URLSessionTask
) -> URLRequest {
    let following = Redirects.followed(
        request,
        from: response.url ?? task.currentRequest?.url,
        startedAt: task.originalRequest
    )
    if following.value(forHTTPHeaderField: Redirects.authorization)
        != request.value(forHTTPHeaderField: Redirects.authorization) {
        // Worth a line even though nothing failed: the hop is invisible
        // otherwise, and a request that arrives without a token is answered
        // 401 by whoever expects one.
        Log.cloud.debug(
            "redirect leaves the origin: the token is not carried to \(following.url?.host() ?? "elsewhere", .public)"
        )
    }
    WireLog.redirected(from: response, to: following)
    return following
}
