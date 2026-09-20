// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// What the server says about the account in the user token.
///
/// This package's own, and the application above has one of its own too: the
/// plan reaches a window, and a window may not name a protocol client. Two
/// fields and a computed answer, converted at the seam by the host — cheaper
/// than either of them depending on the other to say the same two strings.
///
/// The protocol has no endpoint of its own about subscriptions, and there is
/// no reason to invent one: the user token is a JWT, and the plan sits right
/// in its payload. The value is read from a token we already hold, without a
/// single request.
///
/// The level is stored as is, in the server's own wording. It cannot be made
/// an enum: exactly one value has been seen live — `connect`, on an account
/// with a subscription.
///
/// **A plan without Connect has no name: the claim is simply absent.** A
/// free account's token carries no `level` and no `beta` claim at all — 11
/// claims against a subscriber's 13 — and `sync:fox` where the subscriber has
/// `sync:tortoise`. So the absence is the answer rather than a silence, and
/// this type carries it as one: a plan with no level is an account without
/// Connect, while no plan at all still means the token said nothing we could
/// read.
public struct CloudPlan: Sendable, Equatable {
    /// The plan as the server names it — `connect` for a subscriber, and
    /// nothing at all for an account without one.
    public let level: String?
    /// The sync generation the account is allowed: `sync:tortoise` and the
    /// like from the list of scopes. It is what decides whether the library
    /// may be read at all.
    public let syncScope: String?

    public init(level: String?, syncScope: String?) {
        self.level = level
        self.syncScope = syncScope
    }

    /// The Connect subscription.
    ///
    /// `false` now means what it says: either the claim was absent, which is
    /// how an account without Connect answers, or it named a plan we have not
    /// seen. Sync itself does not depend on it — an account without Connect
    /// reads its library perfectly well.
    ///
    /// **Not having Connect is a tier, not the absence of the service.** The
    /// vendor's own pricing (read, so this is their word rather than
    /// our measurement) lists three: free with *limited* storage and sync,
    /// Connect, and Connect for Business. It also says that on the free tier a
    /// file stops syncing to desktop and mobile applications once it has gone
    /// fifty days without an edit — and what hosts this package is a desktop
    /// application. So a library without Connect may be incomplete *by the
    /// service's design*, and
    /// nothing here should present that as a failure of ours.
    public var isConnect: Bool { level == "connect" }
}
