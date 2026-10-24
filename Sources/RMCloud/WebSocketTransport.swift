// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RedactLog
import Synchronization

/// One frame off the push channel, in this package's own words.
///
/// Making `URLSessionWebSocketTask.Message` the currency here would have it
/// travel: the stream would speak it, `NotificationEvent` would parse it, and
/// anything standing in for the socket would have to conjure up a Foundation
/// type it cannot construct. A two-case enum is the whole of what the channel
/// carries instead.
/// Frozen, for the reason given on `CloudError`: this framework ships in lockstep
/// with whatever links it, and an exhaustive `switch` in a consumer is the point.
@frozen
public enum NotificationFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)

    /// The bytes, whichever way they arrived.
    public var data: Data {
        switch self {
        case .text(let text): Data(text.utf8)
        case .binary(let raw): raw
        }
    }

    /// How large the frame was, for the one report that has nothing else to
    /// say about it.
    public var byteCount: Int {
        switch self {
        case .text(let text): text.utf8.count
        case .binary(let raw): raw.count
        }
    }
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness
// the compiler derives — and that witness is internal, so it is absent from
// this module's symbol table when RMCloud is linked as a binary framework.
// The reference resolves in a release build, where the comparison is inlined,
// and fails to link in a debug one. Declaring `==` here puts the comparison
// behind an exported symbol, which costs nothing and keeps `@frozen`: a new
// case must still break a consumer's build rather than fall into an
// `@unknown default`.
extension NotificationFrame {
    public static func == (lhs: NotificationFrame, rhs: NotificationFrame) -> Bool {
        switch (lhs, rhs) {
        case let (.text(left), .text(right)): left == right
        case let (.binary(left), .binary(right)): left == right
        default: false
        }
    }
}

/// A socket that has finished its handshake and is waiting to be read.
public protocol WebSocketReceiving: Sendable {
    /// The next frame. Throws when the socket goes down, which is routine.
    func receive() async throws -> NotificationFrame

    /// Send a ping and wait for the answer.
    ///
    /// The one thing ever written to this socket. The channel is receive-only
    /// and can be silent for hours, so this is what tells a live connection
    /// from one that something in the middle has quietly thrown away — and
    /// what keeps a NAT or a proxy from being the thing that throws it away.
    func ping() async throws

    /// Close it. Called more than once without harm.
    func cancel()
}

/// How a socket is opened.
///
/// The HTTP side of this package has had `HTTPTransporting` from the start, and
/// every response the client can meet is scripted in tests because of it. The
/// websocket side had nothing of the kind, so reconnects, `stop`/`start` and a
/// refused handshake could only be tried against the live service — which means
/// they were tried once, by hand, and never again.
public protocol WebSocketConnecting: Sendable {
    /// A connected socket. The handshake finishes before this returns, so a
    /// refusal arrives here rather than on the first `receive`.
    func connect(to request: URLRequest) async throws -> any WebSocketReceiving
}

/// The little of a websocket task the handshake needs: a ping, and a way to
/// stop waiting for it.
///
/// A seam rather than a convenience. What was broken here was our own wiring —
/// the wait had no cancellation handler on it — and `URLSessionWebSocketTask`
/// was the reason nobody could say so in a test: `WebSocketConnecting` is
/// replaced by a double, but `URLSessionWebSocket.connect` is *below* that port
/// and wants a live `URLSession` to reach. Behind these two methods the wait is
/// a free function over a double, and `URLSessionWebSocket` is the shell around
/// it that it should have been.
protocol HandshakePinging: Sendable {
    /// Send a ping. `answer` is called exactly once, with the failure if there
    /// was one — including the failure that `cancel` causes.
    func sendPing(_ answer: @escaping @Sendable ((any Error)?) -> Void)

    /// Give up, which fails the ping in flight through its own `answer`.
    func cancel()
}

/// Send a ping through `probe` and wait for the answer, ending the wait when
/// the task that asked for it is cancelled.
///
/// Used twice, for the same reason each time: a ping is the only thing this
/// client ever writes to the socket. At the start it forces the handshake to
/// finish — `receive` alone would sit silent on a connection that never came up
/// — and afterwards it is the keepalive, which is the same question asked of a
/// connection that has been quiet for a while.
///
/// The wait needs `withTaskCancellationHandler` because nothing else could end
/// it. A continuation is not a cancellation point, and the only thing that
/// fails a pending ping is `cancel` — so a caller that gave up sat here for
/// `URLSession`'s own timeout, which on an upgrade nobody answers is up to a
/// minute. That is the whole of why `NotificationStream.stop()` can afford to
/// wait for its run: the run's longest wait now ends when it is asked to.
///
/// Resumed exactly once either way. `onCancel` does not call the ping's answer
/// itself; it fails the ping, and the answer invoked for that failure is the
/// same one — the only one — that can resume this continuation.
///
/// The answer itself is not trusted to come once. `URLSessionWebSocketTask`
/// has called a pong handler twice on a connection the network took away
/// under it — `ECONNABORTED` both times — and a second resume of a checked
/// continuation is a trap that takes the process with it. So the first
/// answer is the one that counts, and a second is noted and dropped.
func awaitPong(from probe: some HandshakePinging) async throws {
    let answered = Mutex(false)
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            probe.sendPing { error in
                let first = answered.withLock { was -> Bool in
                    defer { was = true }
                    return !was
                }
                guard first else {
                    Log.cloud.notice("ping answered twice; the second answer was dropped")
                    return
                }
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    } onCancel: {
        probe.cancel()
    }
}

public struct URLSessionWebSocket: WebSocketConnecting {
    /// Internal rather than private for the reason `URLSessionTransport.session`
    /// is: which session the handshake runs on is the one thing about it a test
    /// can check without a server, and it is the thing that decides whether the
    /// token follows a redirect.
    let session: URLSession

    /// The small requests' session by default, and not `URLSession.shared`.
    ///
    /// The upgrade is an HTTP request like any other, and `URLSession` follows
    /// a redirect on it the same silent way: on `.shared` there is no delegate,
    /// so a hop off the origin would carry the Bearer token to whoever answered
    /// there — the exact leak `followRedirect` exists to stop, and this was the
    /// one path in the package it did not cover. `requests` runs under
    /// `RedirectWatcher` and keeps no cache, which is the same promise the rest
    /// of the traffic is held to.
    public init(session: URLSession = URLSessionTransport.requests) {
        self.session = session
    }

    /// The ceiling on a single frame.
    ///
    /// `URLSessionWebSocketTask` defaults to exactly this, and setting it is
    /// about saying so rather than about changing it: a bound on what the
    /// channel may hand us belongs in the code that depends on it. A frame over
    /// the limit fails the socket, which costs a reconnect and nothing else —
    /// the contents were never what a wake rested on.
    public static let frameLimit = 1 << 20

    public func connect(to request: URLRequest) async throws -> any WebSocketReceiving {
        #if os(Linux) || os(Windows)
        return try await NIOWebSocketConnector().connect(to: request)
        #else
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.frameLimit
        task.resume()
        let socket = Socket(task: task)
        do {
            try await awaitPong(from: socket)
        } catch {
            // Read the response before cancelling: cancelling replaces it.
            let refusal = Self.refusal(error, response: task.response)
            task.cancel(with: .abnormalClosure, reason: nil)
            throw refusal
        }
        return socket
        #endif
    }

    /// What a refused handshake actually was.
    ///
    /// The status comes off the task's response, which is the upgrade's own
    /// HTTP reply. Before this the stream decided by the URL error code alone:
    /// any `NSURLErrorBadServerResponse` counted as a 401 and threw the user
    /// token away. But `-1011` is what `URLSession` answers for *every* failed
    /// upgrade — 403, 404, a 500, a proxy's page, anything that is not `101` —
    /// so a service having a bad hour cost a fresh token on every reconnect,
    /// which is how one earns a 429 while trying to recover from a 500. It cut
    /// the other way too: a real 401 and a dead server were indistinguishable,
    /// so neither could be reported for what it was.
    static func refusal(_ error: any Error, response: URLResponse?) -> any Error {
        guard let http = response as? HTTPURLResponse else {
            if let urlError = error as? URLError {
                return transportFailure(urlError)
            }
            return error
        }
        // No refusal in the status means the server was willing and the upgrade
        // failed anyway. Whatever went wrong, the status is not the story.
        return CloudError.fromHTTP(http) ?? error
    }

    /// `URLSessionWebSocketTask` is documented thread-safe — `send`, `receive`
    /// and `cancel` may be called from anywhere — but Foundation does not say
    /// so in the type system. The unchecked conformance is that documented
    /// promise and nothing else: this wrapper holds no state of its own.
    #if canImport(Darwin)
    private struct Socket: WebSocketReceiving, HandshakePinging, @unchecked Sendable {
        let task: URLSessionWebSocketTask

        func sendPing(_ answer: @escaping @Sendable ((any Error)?) -> Void) {
            task.sendPing(pongReceiveHandler: answer)
        }

        /// The keepalive, which is the handshake's own wait asked again later.
        func ping() async throws {
            try await awaitPong(from: self)
        }

        func receive() async throws -> NotificationFrame {
            switch try await task.receive() {
            case .string(let text): .text(text)
            case .data(let raw): .binary(raw)
            // A frame of a kind Foundation has learned about and we have not.
            // Reported empty rather than refused: an unread frame already
            // means "something changed", which is all a frame is trusted for.
            @unknown default: .binary(Data())
            }
        }

        func cancel() {
            task.cancel(with: .goingAway, reason: nil)
        }
    }
    #endif
}
