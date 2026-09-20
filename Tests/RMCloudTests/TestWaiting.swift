// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Testing

/// Spin until something the doubles report comes true, and fail rather than
/// hang when it does not.
///
/// Polled rather than awaited: what is waited for is usually a task parked
/// inside a double, and how long a task takes to reach its next suspension is
/// the scheduler's business — a delay picked here instead would be either flaky
/// or slow. The deadline is only so that a broken run fails with a sentence
/// instead of hanging until the whole suite is killed.
///
/// The first turns are `Task.yield()`, because most of what is waited for is
/// one suspension away and anything slower would make every call site pay for
/// the rare one. After that the loop backs off to a millisecond at a time.
/// Twenty-odd of these run at once in a parallel run of the suite, and a spin
/// that never sleeps holds a cooperative thread against the very task it is
/// waiting for: the deadline then fires and blames the code under test for load
/// the waiting itself created.
///
/// Timed on `ContinuousClock` rather than `Date` for the same reason the
/// deadline exists at all — it should expire when this wait really has taken
/// too long, not when the system clock is adjusted underneath a run.
///
/// The condition is `async` so that state behind an actor can be asked for
/// directly; a synchronous one satisfies it unchanged, which is why the call
/// sites reading a `Mutex` look no different.
func until(
    _ what: String,
    within seconds: TimeInterval = 10,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    var turns = 0
    while ContinuousClock.now < deadline {
        if await condition() { return }
        turns += 1
        if turns > 100 {
            try? await Task.sleep(for: .milliseconds(1))
        } else {
            await Task.yield()
        }
    }
    Issue.record("timed out waiting for \(what)")
}

/// A place two tasks meet: the code under test stops at the gate, and the test
/// lets it through — after learning that it has arrived, if that is what the
/// test is about.
///
/// Written down once rather than per test file, because every copy exists
/// against the same trap: cancel after a delay and hope. A race that may or may
/// not have happened proves nothing, least of all in the tests that are here
/// because a cancellation never arrived at all.
///
/// Deliberately without the deadline `until` carries. What opens a gate is the
/// test itself, so a run parked here is a test that forgot to open it — a
/// mistake in the waiting code, not a condition that never came true.
///
/// The wait to pass is not cancellable on purpose: the tasks held here are the
/// ones the test then cancels, and a gate that let them out on cancellation
/// would release them before the thing under test could happen.
actor Gate {
    private var isOpen = false
    private var arrivals = 0
    private var waitingToPass: [CheckedContinuation<Void, Never>] = []
    private var waitingForArrival: [CheckedContinuation<Void, Never>] = []

    /// Called from the code under test: stop here until the gate opens, and let
    /// the test know something is standing at it.
    func stopHere() async {
        arrivals += 1
        for watcher in waitingForArrival { watcher.resume() }
        waitingForArrival = []
        guard !isOpen else { return }
        await withCheckedContinuation { waitingToPass.append($0) }
    }

    /// Called from the test: return once somebody is standing at the gate.
    func waitForArrival() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { waitingForArrival.append($0) }
    }

    /// Called from the test: let everybody through, those here now and those
    /// arriving later.
    func open() {
        isOpen = true
        for waiter in waitingToPass { waiter.resume() }
        waitingToPass = []
    }
}
