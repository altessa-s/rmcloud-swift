// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// What a token says, read without asking anybody.
///
/// Apart from the actor that fetches and keeps one: these answer from the
/// string alone, so they are checkable on a synthetic token — no network, no
/// Keychain — and they change on the service's schedule for claims rather
/// than on ours for exchanges and retries.
extension TokenProvider {
    /// Whether a token already in hand is still worth handing out.
    ///
    /// A token that says when it dies is judged by that and by nothing else.
    /// How long we have held it is not the same question, and answering the
    /// first with the second is how a token inherited from another process
    /// with six minutes left stayed in memory for twenty hours after it
    /// expired — every request after that a 401.
    ///
    /// `heldSince` is the fallback for the only tokens without an `exp`: ones
    /// of a shape we do not recognise, which are never written to the store
    /// and so never outlive this process.
    ///
    /// Asked with the expiry rather than the token: the caller has it in hand,
    /// read once when the token was cached, and this is asked on every request.
    static func isUsable(expiring expiry: Date?, heldSince: Date?, at moment: Date) -> Bool {
        if let expiry { return isFresh(expiring: expiry, at: moment) }
        guard let heldSince else { return false }
        return moment.timeIntervalSince(heldSince) < userTokenLifetime
    }

    /// Whether a stored token has enough life left to be worth using.
    static func isFresh(_ token: String, at moment: Date) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return isFresh(expiring: expiry, at: moment)
    }

    private static func isFresh(expiring expiry: Date, at moment: Date) -> Bool {
        expiry.timeIntervalSince(moment) > expiryMargin
    }

    /// When the token expires, by its own `exp` claim — seconds since the
    /// epoch, as every JWT spells it.
    static func expiry(of token: String) -> Date? {
        guard let claims = JWT.claims(of: token) else { return nil }
        // Both spellings turn up in JSON: a whole number and a double.
        let seconds = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init)
        return seconds.map { Date(timeIntervalSince1970: $0) }
    }

    /// Which device bought this token, by its own `device-id` claim.
    ///
    /// The registration's identifier, come back from the service — which is why
    /// it is read here rather than out of the store: this is the name the
    /// service knows this client by, and the push channel uses the same one to
    /// say which device caused a change. `nil` for a token of a shape we do not
    /// recognise, and that has to stay `nil`: a guess would make somebody
    /// else's change look like our own and be quietly ignored.
    static func device(fromUserToken token: String) -> String? {
        (JWT.claims(of: token)?["device-id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The parsing is pulled out separately and made static so that it can be
    /// checked on a synthetic token — without the network and without the
    /// Keychain.
    static func plan(fromUserToken token: String) -> CloudPlan? {
        // A token that does not parse says nothing at all — the one case that
        // still answers `nil`. A token that parses without a `level` says
        // something definite: this account has no Connect.
        guard let claims = JWT.claims(of: token) else { return nil }
        let level = (claims["level"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // The scopes arrive on one line, space separated; the only one of
        // interest is the one naming the sync generation.
        let scopes = (claims["scopes"] as? String)?.split(separator: " ").map(String.init) ?? []
        return CloudPlan(
            level: level,
            syncScope: scopes.first { $0.hasPrefix("sync:") }
        )
    }
}
