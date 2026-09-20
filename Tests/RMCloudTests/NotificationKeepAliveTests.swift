// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Synchronization
import Testing

// The socket nobody speaks on.
//
// The channel is receive-only and can be silent for hours, and until now the
// only thing ever written to it was the ping that forces the handshake. A
// connection dropped in the middle — a NAT table, a proxy, a sleeping laptop's
// network — looks to a reader exactly like a quiet one: the read never returns
// and never fails, so push stops and only the poller's interval covers it. A
// keepalive is both halves of the answer: it keeps the path open, and it is the
// one thing that fails when the path is gone.
//
// These run against the doubles rather than the wire, and the interval is
// named in milliseconds so that "every so often" is something a test can
// outlive.

/// The stream, a socket factory, and a token that is fresh until 2100.
private func stream(
    over sockets: any WebSocketConnecting,
    every interval: Duration,
    onSignal: @escaping @Sendable (NotificationSignal) -> Void = { _ in }
) throws -> NotificationStream {
    let secrets = InMemorySecrets()
    try secrets.save("device", as: .deviceToken)
    try secrets.save(liveToken(), as: .userToken)
    return NotificationStream(
        tokens: TokenProvider(transport: ScriptedTransport([]), secrets: secrets),
        sockets: sockets,
        sleeper: RecordingSleeper(),
        pingInterval: interval,
        onSignal: onSignal
    )
}

@Test("A silent socket is pinged while it is held open")
func aSilentSocketIsKeptAlive() async throws {
    // No frames at all: the socket parks, which is exactly the state this
    // exists for — hours of nothing, and no way to tell it from a dead line.
    let sockets = ScriptedSockets([.success([])])
    let live = try stream(over: sockets, every: .milliseconds(10))

    await live.start()
    await until("the socket to be pinged more than once") {
        (sockets.sockets.first?.pingCount ?? 0) >= 2
    }
    await live.stop()

    let socket = try #require(sockets.sockets.first)
    #expect(socket.pingCount >= 2, "the keepalive stopped after the first ping")
}

// The other half. A ping that is not answered is the only news a reader can get
// about a connection that has been thrown away, and news nobody acts on is
// worth nothing: the socket has to come down so the turn ends and the reconnect
// begins.
@Test("A ping that goes unanswered takes the socket down and brings a new one up")
func anUnansweredPingReconnects() async throws {
    let frame = NotificationFrame.text(#"{"message":{"attributes":{"event":"SyncComplete"}}}"#)
    let sockets = ScriptedSockets(
        [
            .success([]),        // parks — and its keepalive is not answered
            .success([frame]),   // the connection that replaces it
        ],
        failingPingOn: [1]
    )
    let seen = SignalLog()
    let live = try stream(over: sockets, every: .milliseconds(10)) { seen.record($0) }

    await live.start()
    await until("the frame from the second socket") { seen.all.contains("SyncComplete") }
    await live.stop()

    #expect(sockets.attempts == 2, "the dead socket was held rather than replaced")
    let first = try #require(sockets.sockets.first)
    #expect(first.isClosed, "the socket that failed its ping was left open")
    #expect(seen.all.filter { $0 == "connected" }.count == 2)
}

// A stream nobody is listening to must not go on speaking to the service. The
// keepalive is a task of its own, and a task of its own is exactly the kind
// that outlives the thing that started it if nobody says otherwise.
@Test("A stopped stream stops pinging")
func aStoppedStreamStopsPinging() async throws {
    let sockets = ScriptedSockets([.success([])])
    let live = try stream(over: sockets, every: .milliseconds(10))

    await live.start()
    await until("the first ping") { (sockets.sockets.first?.pingCount ?? 0) >= 1 }
    await live.stop()

    let socket = try #require(sockets.sockets.first)
    let after = socket.pingCount
    try await Task.sleep(for: .milliseconds(60))
    #expect(socket.pingCount == after, "the keepalive outlived the stream it belonged to")
}
