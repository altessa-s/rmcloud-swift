// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLog

/// The cloud's push channel: a websocket that carries "SyncComplete" when
/// another client finishes writing the root — the `broadcast` flag of the
/// root PUT feeds exactly this stream. Verified live: the sync host accepts
/// the connection with a Bearer user token. Which host that is comes from
/// `EndpointResolver` — discovery publishes one under `notifications`, and on
/// this account it was the sync host itself, which is also what is used when
/// the published name cannot be trusted.
///
/// The stream accelerates the poller, it does not replace it: any frame
/// means "something changed in the account" and wakes an immediate check,
/// while polling stays as the fallback for the stretches when the socket is
/// down. Frames are deliberately not trusted for their contents — the poller
/// re-reads the root anyway, so a spurious wake costs one cheap request.
public actor NotificationStream {
    private let resolver: EndpointResolver
    private let tokens: TokenProvider
    private let sockets: any WebSocketConnecting
    private let sleeper: any Sleeping
    private let onSignal: @Sendable (NotificationSignal) -> Void

    private var connection: Task<Void, Never>?
    private var socket: (any WebSocketReceiving)?

    /// Reconnect pauses: starts small, doubles to a ceiling. A dropped
    /// socket is routine — sleep, network changes — not an error.
    private static let reconnectBase: Duration = .seconds(1)
    private static let reconnectCeiling: Duration = .seconds(60)

    /// How long the socket may stay silent before it is asked whether it is
    /// still there.
    ///
    /// Under the minute an idle connection is commonly given by the things
    /// between here and the service — a NAT table, a proxy — because the point
    /// is to speak before one of them decides nobody is using this. It is not
    /// the service's number: nothing in the protocol states one.
    private let pingInterval: Duration

    public init(
        // Pinned to production by default, which is what naming no host has
        // always meant here: a stream built without one goes where the
        // shipped configuration says and looks no further.
        resolver: EndpointResolver = .pinned(to: .production),
        tokens: TokenProvider,
        sockets: any WebSocketConnecting = URLSessionWebSocket(),
        sleeper: any Sleeping = SystemSleeper(),
        pingInterval: Duration = .seconds(30),
        onSignal: @escaping @Sendable (NotificationSignal) -> Void
    ) {
        self.resolver = resolver
        self.tokens = tokens
        self.sockets = sockets
        self.sleeper = sleeper
        self.pingInterval = pingInterval
        self.onSignal = onSignal
    }

    public func start() {
        guard connection == nil else { return }
        connection = Task { await run() }
    }

    /// Stop, and wait for the run to be gone before letting go of its handle.
    ///
    /// The waiting is the whole of it, the same shape as the host's poller.
    /// Cleared first, the handle guards nothing: the watcher drives `stop`/`start` off
    /// Wi-Fi coming and going, so a `start()` a moment later laid a second run
    /// over one still winding down — and the two shared `socket`. The late
    /// arrival wrote its own connection into that property and then closed
    /// what it found there, which was the live run's socket: a stream that had
    /// just come up went round the backoff for nothing.
    ///
    /// Waiting is only affordable because the handshake is cancellable now
    /// (`URLSessionWebSocket.connect`). While it was not, an attempt parked on
    /// an upgrade nobody would answer held this for `URLSession`'s own
    /// timeout — and the caller waiting here is the one about to erase the
    /// account.
    public func stop() async {
        guard let running = connection else { return }
        running.cancel()
        // Cancelling the task is not enough to end a read already parked:
        // `URLSessionWebSocketTask.receive()` is no cancellation point.
        socket?.cancel()
        // Actor reentrancy is what makes this a wait and not a deadlock: `run`
        // runs on this actor, and it gets in while `stop()` is suspended.
        await running.value
        connection = nil
    }

    private func run() async {
        var failures = 0
        // The socket of the current turn. A local, because closing it belongs
        // to the task that opened it; the property is a different thing — the
        // one handle `stop()` can reach to unblock a parked `receive` — and it
        // holds nothing but the current turn's socket. That the two can never
        // disagree is `stop()`'s doing: it waits for this task before another
        // one may start.
        var live: (any WebSocketReceiving)?
        while !Task.isCancelled {
            // Which token this attempt went out with. A 401 has to name it:
            // by the time a refusal is back the provider may hold a newer
            // token, bought by whoever was refused a moment earlier.
            var sent: String?
            do {
                let token = try await tokens.userToken()
                sent = token
                let opened = try await connect(using: token)
                live = opened
                // The handshake can finish after the stop that cancelled us —
                // it is a round trip, and cancelling only asks. A stream
                // nobody is listening to must not announce itself.
                guard !Task.isCancelled else { break }
                socket = opened
                failures = 0
                Log.cloud.info("notification socket connected")
                onSignal(.connected)
                // Which device the service will call us in a frame it sends
                // because of our own writing. Read off the token that opened
                // this socket rather than out of the store: it is the claim the
                // service itself associates with what this client does, and it
                // costs no request — the token is in hand either way.
                try await listen(
                    to: opened,
                    ownDevice: TokenProvider.device(fromUserToken: token)
                )
            } catch {
                guard !Task.isCancelled else { break }
                // A 401 means the user token aged out mid-connection: refuse
                // the one that was sent, so the next attempt fetches a fresh
                // one and nothing newer is thrown away with it.
                if isUnauthorized(error), let sent {
                    await tokens.invalidateUserToken(sent)
                }
                Log.cloud.debug(
                    "notification socket dropped: \(String(describing: error), .public)"
                )
                onSignal(.dropped(error))
            }
            // Closed rather than merely forgotten: the reconnect opens a
            // second one, and a socket nobody reads still holds a connection.
            close(&live)

            failures += 1
            let backoff = min(
                Self.reconnectBase * (1 << min(failures, 6)),
                Self.reconnectCeiling
            )
            try? await sleeper.sleep(for: backoff)
        }
        // Both ways out of the loop are a `break` past the line above: a
        // handshake that finished after the stop, or a read that failed
        // because of it. Neither may leave a connection open behind us.
        close(&live)
    }

    /// Close the turn's socket, and let go of the copy `stop()` reaches for.
    private func close(_ live: inout (any WebSocketReceiving)?) {
        live?.cancel()
        live = nil
        socket = nil
    }

    private func connect(using token: String) async throws -> any WebSocketReceiving {
        var request = ProtocolRequest.to(await resolver.notificationsHost())
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await sockets.connect(to: request)
    }

    private func listen(to socket: any WebSocketReceiving, ownDevice: String?) async throws {
        // The keepalive runs beside the reading rather than between two frames.
        // The channel goes quiet for hours at a time, and reading is the one
        // thing that cannot tell a live socket from one that something in the
        // middle dropped without telling either end.
        let keepingAlive = Task { await keepAlive(socket) }
        defer { keepingAlive.cancel() }

        while !Task.isCancelled {
            let frame = try await socket.receive()
            guard !Task.isCancelled else { return }
            guard let event = NotificationEvent(frame: frame, ownDevice: ownDevice) else {
                Log.cloud.debug("notification event: unparsed")
                onSignal(.unreadableFrame(frame))
                continue
            }
            Log.cloud.debug("notification event: \(event.event ?? "unnamed", .public)")
            onSignal(.event(event))
        }
    }

    /// Ping while the channel is silent, and end the turn when a ping is not
    /// answered.
    ///
    /// Two things at once, and neither is available any other way. Speaking
    /// keeps the path open: the connection is idle by design — receive-only,
    /// with nothing to say for hours — and idle is what a NAT table or a proxy
    /// collects. And a ping that fails is the only news there is: a connection
    /// thrown away in the middle looks, to the reader, exactly like a quiet
    /// one, so without this push simply stops and the library goes back to
    /// being polled on its interval, late but not wrong.
    ///
    /// `Task.sleep` rather than the injected sleeper. That one is the retry
    /// backoff's, faked to return at once, and a keepalive on it would ping in
    /// a loop as fast as the socket could answer. A test that wants this reach
    /// names a short interval and waits for it.
    private func keepAlive(_ socket: any WebSocketReceiving) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: pingInterval)
                try await socket.ping()
            } catch is CancellationError {
                return
            } catch {
                Log.cloud.debug(
                    "notification socket did not answer a ping: \(String(describing: error), .public)"
                )
                // Closing is what ends the turn: the read is parked and is no
                // cancellation point, so this is the same door `stop()` uses.
                socket.cancel()
                return
            }
        }
    }

    /// Whether the socket was refused for the token rather than for anything
    /// else.
    ///
    /// A question the transport now answers, and it is the only one that can:
    /// the handshake's status lives on the task's response, and every failed
    /// upgrade — 401, 403, 500, a proxy's page — reaches this far as the same
    /// `-1011`. Deciding by that code alone meant a good token was thrown away
    /// on every reconnect while the service was merely unwell, and buying a
    /// new one each time is how the recovery earned itself a 429.
    private func isUnauthorized(_ error: any Error) -> Bool {
        if case CloudError.unauthorized = error { return true }
        return false
    }
}
