// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RedactLog

/// The tokens: the long-lived device token and the short-lived user token,
/// both in the Keychain. Only a ready token is handed outwards, never the
/// store's secrets.
///
/// The user token is kept because it is bought, not made: every process that
/// starts without one exchanges the device token for a fresh one, and a tool
/// run once per page of a notebook is refused with 429 long before the
/// notebook is downloaded. It carries its own expiry in its `exp` claim, so
/// nothing else has to remember when it was issued.
public actor TokenProvider {
    /// How long an in-memory token without an `exp` claim may be reused.
    /// Those tokens are never stored, so this only bounds this process;
    /// twenty hours is "less than a day" without inventing an expiry the
    /// token did not give us.
    static let userTokenLifetime: TimeInterval = 20 * 60 * 60
    /// How much of a token's own life has to be left for it to be worth
    /// using. A token that expires mid-request is a 401 in the middle of a
    /// sync, which is the thing being avoided.
    static let expiryMargin: TimeInterval = 5 * 60

    private let endpoints: CloudEndpoints
    private let transport: any HTTPTransporting
    private let secrets: any CloudSecretStoring
    private let now: @Sendable () -> Date
    /// The same retry policy and the same clock the client runs its protocol
    /// requests under. The auth host is a host like the other, and a 5xx or a
    /// dropped connection there is no more permanent than one on the sync
    /// host — see `send(_:unauthorizedAs:badRequestAs:)`.
    private let policy: RetryPolicy
    private let sleeper: any Sleeping

    private var cachedUserToken: String?
    private var cachedAt: Date?
    /// The cached token's own `exp`, read once when it was cached. Reading it
    /// off the token instead would decode base64 and JSON on every request of
    /// a sync — several hundred of them — to learn a date that cannot change.
    private var cachedExpiry: Date?
    /// The token the server has just refused, kept so that it is not fetched
    /// straight back out of the Keychain. See `invalidateUserToken`.
    private var rejectedUserToken: String?

    /// Which registration session the tokens in hand belong to.
    ///
    /// An actor serialises its statements; it does not hold its lock across an
    /// await. Buying a user token suspends on the request, and `forgetDevice`
    /// is free to run in that gap — so without this check, the exchange could
    /// come back and write its answer into the Keychain for an account that
    /// had just been disconnected. That record lives in the group container,
    /// shared by the app, the extension and `rmctl`, and stays valid until
    /// its own `exp`: up to a day of working credentials for a library the
    /// user was told was gone.
    ///
    /// Bumped at both ends of a registration's life, so the check also covers
    /// a second account connected while the first was still fetching.
    private var registrationSession = 0

    /// The exchange under way, if there is one, and which one it is.
    ///
    /// One exchange, however many callers want a token. `CloudClient` is a
    /// reentrant actor and the host walks the tree with its requests side by
    /// side, so N of them miss the cache — or meet the same expired
    /// token's 401 — in the same moment, and without this, each would buy a
    /// token of its own. Buying is the call the service counts most tightly:
    /// several at once is how a recovery earns itself the 429 that the rest
    /// of this file is written against.
    ///
    /// **Within this process, and only there.** The record is shared with the
    /// app, the extension and `rmctl`, and no actor spans them: three processes
    /// waking together still buy three tokens. Holding that case would take a
    /// lock in the group container — this is not it, and the next reader should
    /// not have to find that out by measuring.
    ///
    /// The id is here because a task cannot recognise itself. The exchange that
    /// settles takes its own handle off the record and never one that by then
    /// belongs to a later exchange — which is possible, because `forgetDevice`
    /// clears this while the task it names is still in the air.
    private var exchange: (id: Int, task: Task<String, any Error>)?
    private var lastExchangeID = 0

    public init(
        endpoints: CloudEndpoints = .production,
        transport: any HTTPTransporting = URLSessionTransport(),
        secrets: any CloudSecretStoring,
        now: @escaping @Sendable () -> Date = Date.init,
        policy: RetryPolicy = .default,
        sleeper: any Sleeping = SystemSleeper()
    ) {
        self.endpoints = endpoints
        self.transport = transport
        self.secrets = secrets
        self.now = now
        self.policy = policy
        self.sleeper = sleeper
    }

    /// What this client calls itself when it registers.
    ///
    /// A constant rather than something a caller may pass, because the server
    /// takes the label from a set of its own: an arbitrary string is refused,
    /// and the two we have seen accepted are this one and `desktop-windows`.
    /// This build runs on a Mac and on nothing else, so there is one right
    /// answer and no question to leave open — an injection point here could
    /// only ever hold a wrong one. The same label comes back in the user
    /// token as the `device-desc` claim, which is how a live account confirms
    /// what was sent.
    static let deviceDescription = "desktop-macos"

    public var isRegistered: Bool {
        get throws { try secrets.secret(.deviceToken) != nil }
    }

    /// Exchanging a one-time code from my.remarkable.com for a device token.
    public func registerDevice(oneTimeCode code: String) async throws {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 8 else { throw CloudError.invalidOneTimeCode }

        // Which session this exchange belongs to, settled before the request
        // goes out. See `registrationSession`: forgetting the device during
        // the flight otherwise lands a working device token in the Keychain
        // moments after the user asked for it to be gone, and a device token
        // is the long-lived one.
        let session = registrationSession

        let deviceID = UUID().uuidString.lowercased()
        let body = try JSONEncoder().encode(
            DeviceTokenRequest(
                code: normalized, deviceDesc: Self.deviceDescription, deviceID: deviceID
            )
        )
        var request = ProtocolRequest.to(endpoints.newDeviceToken, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data = try await send(request, unauthorizedAs: .invalidOneTimeCode)
        let token = try Self.token(in: data, called: "device token")

        guard session == registrationSession else {
            Log.cloud.info("device token arrived after the device was forgotten: dropping it")
            throw CloudError.notRegistered
        }

        try secrets.save(deviceID, as: .deviceID)
        try secrets.save(token, as: .deviceToken)
        try? secrets.forget(.userToken)
        forgetUserToken()
        Log.cloud.info("device registered, device token \(token, .secret)")
    }

    /// Tell the server this Mac is no longer one of the account's devices.
    ///
    /// The Keychain is left alone here, and `forgetDevice` does not call
    /// this: the two fail differently and are reported apart. A revocation
    /// that could not reach the server leaves a registration the account
    /// still lists, and forgetting the token anyway is right — the user asked
    /// for this Mac to stop being able to reach the account, and that much
    /// does not depend on the network. A device the server has already stopped
    /// knowing counts as revoked: the call answers 401 or 403, and what the
    /// caller asked for is true whichever side made it so. With no device
    /// token there is nothing to revoke and nobody to ask.
    ///
    /// Retried like the other two calls to this host, and safely so, because
    /// the rule above makes the call idempotent: a revocation the server
    /// carried out but answered with a 5xx is repeated into a 401, and a 401
    /// is read here as the thing having been done.
    public func revokeDevice() async throws {
        guard let deviceToken = try secrets.secret(.deviceToken) else { return }
        var request = ProtocolRequest.to(endpoints.deleteDeviceToken, method: "POST")
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data()

        do {
            _ = try await send(request)
        } catch CloudError.unauthorized {
            Log.cloud.info("device token already refused by the server: nothing left to revoke")
            return
        }
        Log.cloud.info("device token revoked at the server")
    }

    /// Forget the device: both the token and its identifier.
    public func forgetDevice() throws {
        try secrets.forget(.deviceToken)
        try secrets.forget(.deviceID)
        try? secrets.forget(.userToken)
        forgetUserToken()
    }

    /// Everything this actor remembers about a user token, including which one
    /// was refused: the record is gone, so there is nothing left to recognise.
    ///
    /// The registration session moves with it, which is what stops an exchange
    /// already in flight from putting a token back where these lines just took
    /// one away.
    private func forgetUserToken() {
        cachedUserToken = nil
        cachedAt = nil
        cachedExpiry = nil
        rejectedUserToken = nil
        registrationSession += 1
        // An exchange in the air belongs to the registration that is going
        // away. It is left to run — its own session check drops whatever it
        // brings back — but nobody new may join it: a caller arriving after the
        // *next* registration would otherwise be handed that `notRegistered`
        // for an account that is perfectly well.
        exchange = nil
    }

    /// A current user token; exchanges the device token when needed.
    public func userToken() async throws -> String {
        if let cachedUserToken, Self.isUsable(expiring: cachedExpiry, heldSince: cachedAt, at: now()) {
            return cachedUserToken
        }
        // The store outlives the process, and a token bought a minute ago is
        // as good in this process as it was in the last one. Except the one
        // the server has just refused: that is the token this call exists to
        // get away from.
        if let stored = (try? secrets.secret(.userToken)),
           stored != rejectedUserToken,
           Self.isFresh(stored, at: now()) {
            cache(stored)
            return stored
        }
        // Somebody is already buying one; wait for that rather than buy a
        // second. Safe even for a caller that has just been refused: a 401 in
        // the air while this exchange runs is necessarily about a token bought
        // *before* it, because the one it is about to bring back did not exist
        // when that request went out. There is no token this exchange can
        // return that anybody could already have been told no for.
        if let exchange { return try await exchange.task.value }

        guard let deviceToken = try secrets.secret(.deviceToken) else {
            throw CloudError.notRegistered
        }
        // Unstructured on purpose, and it is the point of the whole field: the
        // exchange belongs to everybody waiting on it rather than to whoever
        // asked first. A child task would go down with that caller — and in the
        // extension the first caller is routinely a Finder request that gives
        // up — taking with it the token the other waiters are still waiting
        // for.
        //
        // A waiter that gives up is therefore not answered early either:
        // `Task.value` on an unstructured task does not observe its awaiter's
        // cancellation, as verified directly, so it waits the exchange out
        // and is handed the token like everyone else. That is the trade
        // taken deliberately.
        // Cutting the wait short would mean a continuation per waiter — what
        // the host does where a document is what is waited for — and it is not
        // worth it here: what is being waited for is one short POST, not a
        // document off the wire.
        //
        // The handle is cleared by the task itself rather than by this caller,
        // for the same reason it is unstructured: cleared here it would go the
        // moment this caller returned by any route at all, and the next arrival
        // would start a second exchange beside the one still running.
        lastExchangeID += 1
        let id = lastExchangeID
        let task = Task<String, any Error> {
            defer { self.endExchange(id) }
            return try await self.buyUserToken(using: deviceToken)
        }
        exchange = (id, task)
        return try await task.value
    }

    /// Hold `token` in memory, with when it was taken and when it says it dies.
    private func cache(_ token: String) {
        cachedUserToken = token
        cachedAt = now()
        cachedExpiry = Self.expiry(of: token)
    }

    /// Take a settled exchange off the record, if it is still the one on
    /// record.
    ///
    /// A failure is not remembered any more than a success is: the next caller
    /// gets a fresh attempt rather than inheriting somebody else's error, as
    /// with the first fill of the index.
    private func endExchange(_ id: Int) {
        guard exchange?.id == id else { return }
        exchange = nil
    }

    /// The exchange itself: device token in, user token out, and everything
    /// that has to be true about the answer before it is kept.
    private func buyUserToken(using deviceToken: String) async throws -> String {
        // Whose token this is about to be. Checked again once the answer is
        // back: see `registrationSession`.
        let session = registrationSession

        var request = ProtocolRequest.to(endpoints.newUserToken, method: "POST")
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data()

        // A 400 here means the account has no tablet. Our request is fixed, so
        // the account is the only thing that can make this call refuse — the
        // same device token refuses before a tablet is paired to the account
        // and succeeds once one is.
        let data = try await send(request, badRequestAs: .accountWithoutTablet)
        let token = try Self.token(in: data, called: "user token")

        guard session == registrationSession else {
            // The device was forgotten, or another one registered, while this
            // exchange was in the air. The token is good and belongs to nobody
            // we still answer for: it is neither kept nor handed out, and the
            // caller is told what is true now rather than what was true when
            // it asked.
            Log.cloud.info("user token arrived for a registration that is gone: dropping it")
            throw CloudError.notRegistered
        }

        // The same question asked of the store: `registrationSession` guards
        // this process only, while the Keychain is shared with the app, the
        // extension and rmctl — and the app disconnecting mid-exchange
        // empties it from outside. Re-read at the moment of keeping: a
        // device token gone or changed means the account this token belongs
        // to has been forgotten, and writing the token back would hand a
        // day-long credential to an account the user has just erased. One
        // read cannot close the window entirely — the Keychain has no
        // transactions — but it shrinks it from the whole exchange to this
        // line.
        guard (try? secrets.secret(.deviceToken)) == deviceToken else {
            Log.cloud.info("user token arrived after the account left the Keychain: dropping it")
            throw CloudError.notRegistered
        }

        cache(token)
        // The server has spoken again, so whatever it refused before is no
        // longer the thing standing in the way — and holding on to it would
        // make a token it has just handed back unusable.
        rejectedUserToken = nil
        // Kept only when it says when it dies, and only while it still has a
        // life to spend. A token whose shape we do not recognise would have to
        // be trusted on a timestamp of our own; one already past its `exp` is
        // a 401 stored for the next process to trip over.
        //
        // A store that refuses the write is not a failure of this exchange —
        // the token in hand is good and is handed out — but it is not silent
        // either: without the record every process buys a token of its own,
        // and several of them at once is how a recovery earns itself the 429
        // this file is written against. The line is what says why.
        do {
            if Self.isFresh(token, at: now()) {
                try secrets.save(token, as: .userToken)
            } else {
                try secrets.forget(.userToken)
            }
        } catch {
            Log.cloud.error(
                "the user token could not be kept in the store: \(String(describing: error), .public)"
            )
        }
        Log.cloud.debug("got user token \(token, .secret)")
        return token
    }

    /// One request to the auth host, sent and checked under the client's own
    /// retry policy, and the body it answered with.
    ///
    /// The three calls to this host used to go out once, bare, while every
    /// protocol request went through `withRetry`. That made the token the
    /// weakest link of a sync: the user token is bought on a schedule, in the
    /// middle of whatever the client was doing, and one 503 or one dropped
    /// connection on that exchange failed the request that needed it — a
    /// request which, had it been about a blob, would simply have been tried
    /// again.
    ///
    /// The validation is inside the attempt rather than after it, because that
    /// is where the retry decision is made: a 5xx has to become
    /// `CloudError.http` before the policy can see it. What must not be
    /// repeated is not, by the same policy: 401 becomes `unauthorized` (or
    /// what `unauthorizedAs` names, a wrong one-time code), 400 becomes
    /// `badRequestAs` where a caller has a reading for it, and neither is one
    /// the policy retries — `RetryPolicy.shouldRetry` says so, and the tests
    /// hold it to that.
    private func send(
        _ request: URLRequest,
        unauthorizedAs unauthorized: CloudError = .unauthorized,
        badRequestAs badRequest: CloudError? = nil
    ) async throws -> Data {
        // A local copy, as `CloudClient` takes one: the attempt must not
        // capture the actor, only what it needs from it.
        let transport = transport
        return try await withRetry(policy: policy, sleeper: sleeper) {
            let (data, response) = try await transport.send(request)
            do {
                try transport.validate(response, unauthorizedAs: unauthorized)
            } catch let error as CloudError {
                if case .http(status: 400, _) = error, let badRequest { throw badRequest }
                throw error
            }
            return data
        }
    }

    /// The token a response body is, when it is one at all.
    ///
    /// Both exchanges answer with the bare token as the body, and both are
    /// held to the same rule: a garbled response must fail here, visibly.
    /// `String(decoding:)` would paper over broken UTF-8 with replacement
    /// characters, and the corrupted token would surface later as an
    /// inexplicable 401 — for a day, in the case of a user token cached here.
    /// `called` is what the failure names, so that the two are told apart.
    private static func token(in data: Data, called what: String) throws -> String {
        guard let token = String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { throw CloudError.malformedResponse("\(what) is empty or not UTF-8") }
        return token
    }

    /// The account plan from the user token's claims.
    ///
    /// It makes no request of its own: the token is fetched for every check
    /// against the cloud anyway, and a JWT payload is just base64 in the
    /// middle of it. `nil` means "the server did not say" rather than "there
    /// is no subscription": an unfamiliar token shape must not be passed off
    /// as the absence of a plan.
    public func plan() async throws -> CloudPlan? {
        Self.plan(fromUserToken: try await userToken())
    }

    /// Drop the token after a 401: the next request will go for a new one.
    ///
    /// Clearing the memory alone would not be enough. The store outlives the
    /// process and is shared between the app, the extension and `rmctl`, so
    /// the very next `userToken()` would read the refused token straight
    /// back — while it is still fresh by its own `exp`, which is exactly the
    /// case a revoked token is — and the retry would go out with the same
    /// `Authorization`. Until the token expired on its own, hours later,
    /// nothing could mend the account.
    ///
    /// What is remembered is the refused value, not an order to delete the
    /// record: another process may have bought a good token in the meantime,
    /// and throwing that away would cost it a needless exchange — and us the
    /// 429 that comes of several processes buying at once.
    /// `refused` is the token the server said no to — the one that went out on
    /// the request, not whatever is in hand when the refusal gets back. The
    /// two are the same only when nothing happened in between, and something
    /// usually does: this actor is reentrant, a walk over the tree runs its
    /// requests side by side, and an expired token is refused on all of them at
    /// once. The first refusal buys a replacement; the second, about the very
    /// same dead token, would otherwise find that replacement already in the
    /// cache and mark it refused too. The next `userToken()` would then read
    /// the fresh token back out of the Keychain, recognise it as the rejected
    /// one, and buy a third — the very method that exists to avoid a needless
    /// exchange causing one, and several of them at once earning a 429.
    public func invalidateUserToken(_ refused: String) {
        rejectedUserToken = refused
        // Cleared only when the accusation is about what is actually held.
        // A token bought since is a different token and answers for itself.
        guard cachedUserToken == refused else { return }
        cachedUserToken = nil
        cachedAt = nil
        cachedExpiry = nil
    }

    private struct DeviceTokenRequest: Encodable {
        let code: String
        let deviceDesc: String
        let deviceID: String
    }
}
