// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The wait between attempts. A separate type so that tests do not really
/// sleep.
public protocol Sleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemSleeper: Sleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// When to repeat a request and after how long.
public struct RetryPolicy: Sendable {
    /// Attempts in total, the first one included.
    public var maxAttempts: Int
    /// The delay before the second attempt.
    public var baseDelay: Duration
    /// How many times over the delay grows.
    public var multiplier: Double
    /// The delay ceiling: a server that has asked to wait an hour must not
    /// hang syncing — better to return an error and retry on schedule.
    public var maxDelay: Duration
    /// The random spread around the computed delay, as a fraction of it.
    /// The library is read with up to eight concurrent requests: one server
    /// hiccup fails several of them at once, and without a spread they all
    /// come back in a synchronized burst.
    public var jitter: Double

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(300),
        multiplier: Double = 3,
        maxDelay: Duration = .seconds(20),
        jitter: Double = 0.2
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    public static let `default` = RetryPolicy()

    /// We repeat only what may go through on a second try: the network, 5xx
    /// and an explicit request to wait. A wrong token, a 400 and a broken
    /// schema will not be fixed by repeating.
    public func shouldRetry(_ error: CloudError) -> Bool {
        switch error {
        case .transport, .rateLimited:
            true
        case .http(let status, _), .writeRejected(let status, _):
            (500...599).contains(status)
        // A root conflict does get retried, but not here: repeating the same
        // write would point the root at a tree built on a generation that has
        // stopped being current. The writer above re-reads the root and
        // rebuilds before trying again.
        // `missingHash` is ours rather than the server's: asking again with
        // the same nothing would get the same nothing.
        // `noRootYet` is a state and not a failure: repeating the request would
        // get the same truthful 404 until the tablet syncs something.
        // `oversizedResponse` says the answer was not the protocol's at all,
        // which asking again does not mend.
        // `notOnThisPlan` least of all: a subscription does not appear because
        // it was asked twice.
        // `nothingToAsk` is ours as well, and the plainest of them: a request
        // that was never sent has nothing to send again.
        case .notOnThisPlan, .nothingToAsk,
             .notRegistered, .invalidOneTimeCode, .unauthorized,
             .unsupportedSchema, .malformedIndex, .malformedResponse, .hashMismatch,
             .rootConflict, .missingHash, .noRootYet, .accountWithoutTablet,
             .oversizedResponse:
            false
        }
    }

    /// The delay before attempt number `attempt` (numbered from 1). The
    /// server's `Retry-After` outranks our formula — and gets no jitter: the
    /// server named the time itself — but is under the ceiling too.
    ///
    /// `random` is a parameter for the tests' sake: delays with real
    /// randomness in them cannot be compared to exact values.
    public func delay(
        beforeAttempt attempt: Int,
        retryAfter: TimeInterval?,
        random: (ClosedRange<Double>) -> Double = { .random(in: $0) }
    ) -> Duration {
        if let retryAfter, retryAfter > 0 {
            return min(.seconds(retryAfter), maxDelay)
        }
        let exponent = max(0, attempt - 2)
        let seconds = baseDelay.seconds * pow(multiplier, Double(exponent))
        let spread = seconds * jitter
        return min(.seconds(seconds + random(-spread...spread)), maxDelay)
    }
}

public extension Duration {
    /// Seconds as a number — for delay arithmetic and comparisons in tests.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Run an operation with retries according to a policy.
///
/// Returns the result of the first successful attempt; when the attempts run
/// out it throws the last error rather than one of its own: the caller needs
/// the reason, not the fact of exhaustion.
public func withRetry<T>(
    policy: RetryPolicy = .default,
    sleeper: any Sleeping = SystemSleeper(),
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch let error as CloudError {
            guard attempt < policy.maxAttempts, policy.shouldRetry(error) else { throw error }
            var retryAfter: TimeInterval?
            if case .rateLimited(let interval) = error { retryAfter = interval }
            attempt += 1
            try await sleeper.sleep(for: policy.delay(beforeAttempt: attempt, retryAfter: retryAfter))
        }
    }
}
