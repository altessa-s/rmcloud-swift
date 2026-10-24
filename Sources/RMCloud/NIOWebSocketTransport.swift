// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

#if os(Linux) || os(Windows)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIO
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import Synchronization

/// The public connector keeps its historical name; only its platform backend changes.
struct NIOWebSocketConnector: WebSocketConnecting {
    var handshakeTimeout: TimeAmount = .seconds(30)
    var pingTimeout: TimeAmount = .seconds(10)

    // Connections share one bounded I/O thread rather than allocating a thread on every reconnect.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    func connect(to request: URLRequest) async throws -> any WebSocketReceiving {
        guard let url = request.url, let host = url.host,
              let scheme = url.scheme, ["ws", "wss"].contains(scheme) else {
            throw URLError(.badURL)
        }
        let tls = scheme == "wss"
        // Cleartext only where there is no wire to listen on: the service this
        // package talks to is `wss`, and a `ws` URL reaching a real host would
        // carry the socket token in the open. Loopback is allowed because the
        // tests have no certificate to present.
        let loopback = host == "127.0.0.1" || host == "::1" || host == "localhost"
        guard tls || loopback else { throw URLError(.secureConnectionFailed) }
        let port = url.port ?? (tls ? 443 : 80)
        let loop = Self.group.next()
        let ready = loop.makePromise(of: Void.self)
        let handshake = UpgradeResponse(request: request, ready: ready)
        let frames = Frames(pingTimeout: pingTimeout)
        let cancellation = ConnectionCancellation()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let channel = try await ClientBootstrap(group: loop)
                    .connectTimeout(.seconds(30))
                    .channelInitializer { channel in
                        cancellation.install(channel)
                        return channel.eventLoop.makeCompletedFuture {
                            if tls {
                                let context = try NIOSSLContext(configuration: .makeClientConfiguration())
                                // IP literals cannot appear in SNI; NIOSSL verifies the peer IP in that case.
                                let serverName = (try? SocketAddress(ipAddress: host, port: port)) == nil ? host : nil
                                let handler = try NIOSSLClientHandler(context: context, serverHostname: serverName)
                                try channel.pipeline.syncOperations.addHandler(handler)
                            }
                            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
                            let upgrader = NIOWebSocketClientUpgrader(
                                requestKey: key,
                                maxFrameSize: URLSessionWebSocket.frameLimit,
                                automaticErrorHandling: true
                            ) { channel, _ in
                                channel.pipeline.addHandler(frames).flatMap {
                                    channel.pipeline.removeHandler(handshake)
                                }.map { handshake.succeed() }
                            }
                            try channel.pipeline.syncOperations.addHTTPClientHandlers(
                                withClientUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                            )
                            try channel.pipeline.syncOperations.addHandler(handshake)
                        }
                    }
                    .connect(host: host, port: port).get()
                let timeout = loop.scheduleTask(in: handshakeTimeout) {
                    handshake.fail(URLError(.timedOut))
                    channel.close(promise: nil)
                }
                defer { timeout.cancel() }
                try await ready.futureResult.get()
                try Task.checkCancellation()
                let socket = Socket(channel: channel, frames: frames)
                // Like the system backend, connect proves the peer answers before returning.
                try await socket.ping()
                return socket
            } catch {
                loop.execute { handshake.fail(error) }
                cancellation.cancel()
                if Task.isCancelled { throw CancellationError() }
                if let error = error as? URLError { throw transportFailure(error) }
                // Already named by the handshake — an HTTP refusal carries its
                // status, and that is information the caller acts on.
                if error is CloudError { throw error }
                if error is CancellationError { throw error }
                // A refused socket or a failed TLS handshake arrives as
                // neither a `URLError` nor a `CloudError`, and every caller of
                // this package knows one name for "the wire did not carry it".
                throw CloudError.transport(code: (error as NSError).code)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

}

private final class ConnectionCancellation: Sendable {
    private let state = Mutex<(cancelled: Bool, channel: Channel?)>((false, nil))
    func install(_ channel: Channel) {
        let cancelled = state.withLock { value in
            value.channel = channel
            return value.cancelled
        }
        if cancelled { channel.close(promise: nil) }
    }
    func cancel() {
        let channel = state.withLock { value in
            value.cancelled = true
            return value.channel
        }
        channel?.close(promise: nil)
    }
}

private struct Socket: WebSocketReceiving {
    let channel: Channel
    let frames: Frames

    func receive() async throws -> NotificationFrame {
        try await withTaskCancellationHandler {
            let promise = channel.eventLoop.makePromise(of: NotificationFrame.self)
            channel.eventLoop.execute { frames.receive(promise) }
            return try await promise.futureResult.get()
        } onCancel: { cancel() }
    }

    func ping() async throws {
        try await withTaskCancellationHandler {
            let promise = channel.eventLoop.makePromise(of: Void.self)
            channel.eventLoop.execute { frames.ping(promise, channel: channel) }
            try await promise.futureResult.get()
        } onCancel: { cancel() }
    }

    func cancel() { channel.close(promise: nil) }
}

// NIO invokes handlers on one event loop; all mutable fields stay on that loop.
private final class UpgradeResponse: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let request: URLRequest
    let ready: EventLoopPromise<Void>
    var finished = false

    init(request: URLRequest, ready: EventLoopPromise<Void>) {
        self.request = request
        self.ready = ready
    }

    func succeed() {
        guard !finished else { return }
        finished = true
        ready.succeed(())
    }

    func fail(_ error: any Error) {
        guard !finished else { return }
        finished = true
        ready.fail(error)
    }

    func channelActive(context: ChannelHandlerContext) {
        guard let url = request.url, let host = url.host else {
            fail(URLError(.badURL)); context.close(promise: nil); return
        }
        var headers = HTTPHeaders((request.allHTTPHeaderFields ?? [:]).map { ($0.key, $0.value) })
        let hostname = host.contains(":") ? "[\(host)]" : host
        headers.replaceOrAdd(name: "Host", value: url.port.map { "\(hostname):\($0)" } ?? hostname)
        // NIO's upgrader supplies Connection, Upgrade, the random key and version 13.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? ""
        let uri = (path.isEmpty ? "/" : path) + (components?.percentEncodedQuery.map { "?" + $0 } ?? "")
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, method: .GET, uri: uri, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            let response = request.url.flatMap {
                HTTPURLResponse(url: $0, statusCode: Int(head.status.code), httpVersion: "HTTP/1.1",
                                headerFields: Dictionary(head.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }))
            }
            fail(URLSessionWebSocket.refusal(URLError(.badServerResponse), response: response))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(URLError(.networkConnectionLost))
        context.fireChannelInactive()
    }
}

// Socket methods enqueue work on this handler's event loop before accessing its state.
private final class Frames: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let pingTimeout: TimeAmount

    init(pingTimeout: TimeAmount) { self.pingTimeout = pingTimeout }

    var queued: [NotificationFrame] = []
    var queuedBytes = 0
    var readers: [EventLoopPromise<NotificationFrame>] = []
    var pings: [String: (EventLoopPromise<Void>, Scheduled<Void>)] = [:]
    var failure: (any Error)?
    var fragmentedOpcode: WebSocketOpcode?
    var fragments = Data()

    func receive(_ promise: EventLoopPromise<NotificationFrame>) {
        if !queued.isEmpty {
            let frame = queued.removeFirst()
            queuedBytes -= frame.byteCount
            promise.succeed(frame)
        } else if let failure { promise.fail(failure) } else { readers.append(promise) }
    }

    func ping(_ promise: EventLoopPromise<Void>, channel: Channel) {
        if let failure { promise.fail(failure); return }
        guard channel.isActive else { promise.fail(URLError(.networkConnectionLost)); return }
        let key = UUID().uuidString
        let timeout = channel.eventLoop.scheduleTask(in: pingTimeout) {
            self.fail(URLError(.timedOut))
            channel.close(promise: nil)
        }
        pings[key] = (promise, timeout)
        var payload = channel.allocator.buffer(capacity: key.utf8.count)
        payload.writeString(key)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .ping, maskKey: .random(), data: payload)).whenFailure { error in
            self.fail(error)
            channel.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        var payload = frame.unmaskedData
        // No extensions were negotiated, and a server must never mask its frames.
        guard frame.maskKey == nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else { reject(context); return }
        if frame.opcode == .ping || frame.opcode == .pong || frame.opcode == .connectionClose {
            guard frame.fin, payload.readableBytes <= 125 else { reject(context); return }
        }
        switch frame.opcode {
        case .pong:
            if let key = payload.readString(length: payload.readableBytes),
               let (promise, timer) = pings.removeValue(forKey: key) {
                timer.cancel()
                promise.succeed(())
            }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: payload)), promise: nil)
        case .connectionClose:
            fail(URLError(.networkConnectionLost))
            let channel = context.channel
            let reply = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: payload)
            context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in
                channel.close(promise: nil)
            }
        case .text, .binary, .continuation:
            if frame.opcode != .continuation {
                guard fragmentedOpcode == nil else { reject(context); return }
                fragmentedOpcode = frame.opcode
            } else if fragmentedOpcode == nil { reject(context); return }
            guard fragments.count + payload.readableBytes <= URLSessionWebSocket.frameLimit else { reject(context); return }
            fragments.append(contentsOf: payload.readableBytesView)
            guard frame.fin else { return }
            let message: NotificationFrame
            if fragmentedOpcode == .text {
                guard let text = String(data: fragments, encoding: .utf8) else { reject(context); return }
                message = .text(text)
            } else { message = .binary(fragments) }
            fragments = Data()
            fragmentedOpcode = nil
            if !readers.isEmpty { readers.removeFirst().succeed(message) } else {
                // A peer must not allocate unbounded memory while the consumer is busy.
                guard queued.count < 1024, queuedBytes + message.byteCount <= URLSessionWebSocket.frameLimit else { reject(context); return }
                queued.append(message)
                queuedBytes += message.byteCount
            }
        default: reject(context)
        }
    }

    func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        for reader in readers { reader.fail(error) }
        readers.removeAll()
        for (promise, timer) in pings.values { timer.cancel(); promise.fail(error) }
        pings.removeAll()
    }

    private func reject(_ context: ChannelHandlerContext) {
        fail(URLError(.badServerResponse))
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(URLError(.networkConnectionLost))
        context.fireChannelInactive()
    }
}
#endif
