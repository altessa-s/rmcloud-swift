// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RedactLog

/// The protocol client: the root, the indexes, the blobs — and, since the
/// volume learned to write, the uploads and the root pointer as well.
///
/// One actor — one place where the token, the host and the retries are
/// settled — laid out by what it is asked about:
/// `+Reading` for the root, the indexes and the blobs, `+Writing` for the
/// uploads and the pointer, `+Requests` for the machinery underneath both.
/// What stays here is what they share: the state, the two initialisers, the
/// protocol's own names, and the one thing the pointer says that nobody acts
/// on.
public actor CloudClient {
    let resolver: EndpointResolver
    let transport: any HTTPTransporting
    let tokens: TokenProvider
    let policy: RetryPolicy
    let sleeper: any Sleeping

    /// Which root path answered the read on this account. Settled by the
    /// first read that answers, and unsettled again by a 404 on it — see
    /// `root()`.
    ///
    /// A cache for reading and nothing else. The write does not consult it —
    /// see `CloudEndpoints.rootWrite` for why the two are allowed to differ.
    var rootVersion: CloudEndpoints.RootVersion?

    public init(
        resolver: EndpointResolver,
        transport: any HTTPTransporting = URLSessionTransport(),
        tokens: TokenProvider,
        policy: RetryPolicy = .default,
        sleeper: any Sleeping = SystemSleeper()
    ) {
        self.resolver = resolver
        self.transport = transport
        self.tokens = tokens
        self.policy = policy
        self.sleeper = sleeper
    }

    /// A client fixed to the hosts it is given.
    ///
    /// For a fake server and for the debugging client's overrides: naming a
    /// host is a decision, and a client built this way does not go looking for
    /// another one. The resolving initialiser above is what a shipped build
    /// uses.
    public init(
        endpoints: CloudEndpoints = .production,
        transport: any HTTPTransporting = URLSessionTransport(),
        tokens: TokenProvider,
        policy: RetryPolicy = .default,
        sleeper: any Sleeping = SystemSleeper()
    ) {
        self.init(
            resolver: .pinned(to: endpoints),
            transport: transport,
            tokens: tokens,
            policy: policy,
            sleeper: sleeper
        )
    }
    /// What the pointer said last time, so that a repetition is silent and a
    /// change is not. See `RootAdvisory`.
    private var lastAdvisory: RootAdvisory?

    /// Say what the pointer says about itself, once per change.
    ///
    /// Fed by the read and never by the write: a write answers with the hash
    /// and the generation alone, and comparing that against a read would report
    /// every field as having vanished on every commit.
    func note(_ advisory: RootAdvisory) {
        let remarks = advisory.remarks(since: lastAdvisory)
        lastAdvisory = advisory
        guard !remarks.isEmpty else { return }
        let text = remarks.joined(separator: "; ")
        // The ordinary state of an account is a diagnostic; the service saying
        // something this client does not implement is not.
        if advisory.isOrdinary {
            Log.cloud.debug("root pointer: \(text, .public)")
        } else {
            Log.cloud.notice("root pointer: \(text, .public)")
        }
    }
}
