// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import RMLog
import Synchronization
import Testing

/// A sleeper that waits for nothing but remembers how long it was asked for.
final class RecordingSleeper: Sleeping {
    private let recorded = Mutex<[Duration]>([])

    var delays: [Duration] { recorded.withLock { $0 } }

    func sleep(for duration: Duration) async throws {
        recorded.withLock { $0.append(duration) }
    }
}

// MARK: - Policy

@Test("We retry network, 5xx and an explicit wait")
func retriesTransientFailures() {
    let policy = RetryPolicy.default
    #expect(policy.shouldRetry(.transport(code: -1009)))
    #expect(policy.shouldRetry(.http(status: 503, path: "/sync/v3/root")))
    #expect(policy.shouldRetry(.rateLimited(retryAfter: 5)))
}

@Test("We do not retry what a retry cannot fix")
func doesNotRetryPermanentFailures() {
    let policy = RetryPolicy.default
    #expect(policy.shouldRetry(.unauthorized) == false)
    #expect(policy.shouldRetry(.http(status: 400, path: "/sync/v3/files/abc")) == false)
    #expect(policy.shouldRetry(.unsupportedSchema("9")) == false)
    #expect(policy.shouldRetry(.hashMismatch(expected: "a", actual: "b")) == false)
    #expect(policy.shouldRetry(.notRegistered) == false)
}

@Test("The delay grows by the multiplier")
func delayGrows() {
    let policy = RetryPolicy(maxAttempts: 4, baseDelay: .milliseconds(100), multiplier: 3)
    // Compared with a tolerance: delays are computed in Double, where
    // 0.1 × 3 comes out as 0.30000000000000004. The randomness is pinned to
    // zero — the formula is under test here, not the spread.
    func isClose(_ duration: Duration, _ expected: Double) -> Bool {
        abs(duration.seconds - expected) < 0.001
    }
    func delay(_ attempt: Int) -> Duration {
        policy.delay(beforeAttempt: attempt, retryAfter: nil, random: { _ in 0 })
    }

    #expect(isClose(delay(2), 0.1))
    #expect(isClose(delay(3), 0.3))
    #expect(isClose(delay(4), 0.9))
}

@Test("The delay is spread out so concurrent retries do not chorus")
func delayCarriesJitter() {
    let policy = RetryPolicy(baseDelay: .seconds(1), jitter: 0.2)

    // The edges of the spread stay within ±jitter of the formula.
    #expect(policy.delay(beforeAttempt: 2, retryAfter: nil, random: \.lowerBound).seconds == 0.8)
    #expect(policy.delay(beforeAttempt: 2, retryAfter: nil, random: \.upperBound).seconds == 1.2)
    // The server's own Retry-After is not second-guessed.
    #expect(policy.delay(beforeAttempt: 2, retryAfter: 5, random: \.upperBound).seconds == 5)
}

@Test("Retry-After beats the formula but stays under the cap")
func honoursRetryAfterWithCeiling() {
    let policy = RetryPolicy(maxDelay: .seconds(20))
    #expect(policy.delay(beforeAttempt: 2, retryAfter: 7).seconds == 7)
    #expect(policy.delay(beforeAttempt: 2, retryAfter: 3600).seconds == 20, "an hour of waiting would stall syncing")
}

// MARK: - Execution

@Test("Success on the second attempt is invisible to the caller")
func succeedsAfterRetry() async throws {
    let sleeper = RecordingSleeper()
    let attempts = Mutex(0)

    let value = try await withRetry(policy: .default, sleeper: sleeper) {
        let attempt = attempts.withLock { count -> Int in
            count += 1
            return count
        }
        if attempt == 1 { throw CloudError.transport(code: -1009) }
        return "done"
    }

    #expect(value == "done")
    #expect(attempts.withLock { $0 } == 2)
    #expect(sleeper.delays.count == 1)
}

@Test("When attempts run out the last error is thrown, not our own")
func rethrowsLastError() async {
    let sleeper = RecordingSleeper()
    let policy = RetryPolicy(maxAttempts: 3)

    await #expect(throws: CloudError.http(status: 503, path: "/x")) {
        try await withRetry(policy: policy, sleeper: sleeper) {
            throw CloudError.http(status: 503, path: "/x")
        }
    }
    #expect(sleeper.delays.count == 2, "three attempts, two pauses")
}

@Test("An unrecoverable error does not spend attempts")
func doesNotSleepOnPermanentFailure() async {
    let sleeper = RecordingSleeper()

    await #expect(throws: CloudError.unauthorized) {
        try await withRetry(sleeper: sleeper) { throw CloudError.unauthorized }
    }
    #expect(sleeper.delays.isEmpty)
}

// MARK: - Masking

@Test("A token cannot be reconstructed from the log")
func masksSecrets() {
    let masked = Log.masked("abcd1234efgh")
    #expect(masked.contains("abcd") == false)
    #expect(masked.contains("1234") == false)
    // The length stays: it is the cheapest way to see that a token was
    // replaced by something of another shape entirely.
    #expect(masked.contains("12"))
    #expect(Log.masked("") == "<empty>")

    // Two tokens of one service differ in their claims and nowhere else that
    // a prefix would show: every JWT it issues starts with the same header.
    let first = Log.masked("eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.signature")
    let second = Log.masked("eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjJ9.signature")
    #expect(first != second)
    #expect(first.contains("eyJ") == false)
}

@Test("A document name never reaches the log")
func masksNames() {
    let masked = Log.maskedUserText("Private diary.pdf")
    #expect(masked.contains("diary") == false)
    #expect(masked.hasSuffix(".pdf"), "the extension stays: it tells what the file is")
}
