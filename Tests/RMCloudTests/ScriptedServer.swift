// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIO
import NIOHTTP1
import NIOWebSocket
import Synchronization

/// A separate ephemeral listener per test makes interception independent of URLSession's backend.
final class ScriptedServer: Sendable {
    struct Script: Sendable {
        var status = 200
        var isHTTP = true
        var redirectsTo: URL?
        var declaresLength = true
        var chunks: [Data] = []
        var parks = false
        var pace: TimeInterval = 0.005
        var stallsUntilStopped: Int?
        var headers: [String: String] = [:]
        var webSocket = false
        var pongLimit: Int?
    }

    fileprivate struct Exchange: Sendable {
        let script: Script
        var reached = false
        var delivered = 0
        var stopped = false
        var headers: [String: String] = [:]
    }

    fileprivate final class State: Sendable {
        let exchanges = Mutex<[String: Exchange]>([:])
        let clients = Mutex<[Channel]>([])
    }

    private let state = State()
    private let group: MultiThreadedEventLoopGroup
    private let listener: Channel
    private let stopped = Mutex(false)

    init() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let state = self.state
        do {
            listener = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    state.clients.withLock { $0.append(channel) }
                    let http = Handler(state: state)
                    let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { channel, head in
                        let accepts = state.exchanges.withLock { exchanges in
                            exchanges[head.uri]?.reached = true
                            exchanges[head.uri]?.headers = Dictionary(
                    head.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }
                )
                            return exchanges[head.uri]?.script.webSocket ?? false
                        }
                        return channel.eventLoop.makeSucceededFuture(accepts ? HTTPHeaders() : nil)
                    }, upgradePipelineHandler: { channel, head in
                        let script = state.exchanges.withLock { $0[head.uri]?.script ?? Script() }
                        return channel.pipeline.addHandler(WebSocketPeer(script: script))
                    })
                    // Each connection serves one script. Keep reading even when a parked
                    // response never finishes, so the peer's EOF reaches channelInactive.
                    return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withServerUpgrade: (
                        upgraders: [upgrader], completionHandler: { context in
                            context.pipeline.removeHandler(http, promise: nil)
                        }
                    )).flatMap { channel.pipeline.addHandler(http) }
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        guard stopped.withLock({ value in
            defer { value = true }
            return !value
        }) else { return }
        try? listener.close().wait()
        for channel in state.clients.withLock({ $0 }) { try? channel.close().wait() }
        try? group.syncShutdownGracefully()
    }

    deinit { stop() }

    func expect(_ script: Script, host: String = "sync.invalid") -> URL {
        // Different host spelling gives redirect tests a distinct origin on the same listener.
        let hostname = host == "sync.invalid" ? "127.0.0.1" : "localhost"
        let path = "/sync/v3/files/\(UUID().uuidString)"
        let url = URL.constant("http://\(hostname):\(listener.localAddress?.port ?? 0)\(path)")
        state.exchanges.withLock { $0[path] = Exchange(script: script) }
        return url
    }

    func reached(_ url: URL) -> Bool { state.exchanges.withLock { $0[url.path]?.reached ?? false } }
    func headers(_ url: URL) -> [String: String] { state.exchanges.withLock { $0[url.path]?.headers ?? [:] } }
    func delivered(_ url: URL) -> Int { state.exchanges.withLock { $0[url.path]?.delivered ?? 0 } }
    func stops(_ url: URL) async -> Bool {
        await until("the client to close its connection") {
            self.state.exchanges.withLock { $0[url.path]?.stopped ?? false }
        }
        return state.exchanges.withLock { $0[url.path]?.stopped ?? false }
    }

    func session(delegate: (any URLSessionDelegate)? = nil) -> URLSession {
        URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

}

// The peer deliberately fragments text and interleaves control frames to exercise reassembly.
// Mutable ping counts are confined to the channel event loop.
private final class WebSocketPeer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let script: ScriptedServer.Script
    var pings = 0

    init(script: ScriptedServer.Script) { self.script = script }

    func handlerAdded(context: ChannelHandlerContext) {
        for (index, chunk) in script.chunks.enumerated() {
            var buffer = context.channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            let frame = WebSocketFrame(fin: index == script.chunks.count - 1,
                                       opcode: index == 0 ? .text : .continuation, data: buffer)
            context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if frame.opcode == .ping {
            pings += 1
            if let limit = script.pongLimit, pings > limit { return }
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        } else if frame.opcode == .connectionClose { context.close(promise: nil) }
    }
}

// Handler state is confined to its channel's event loop, including scheduled writes.
private final class Handler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let state: ScriptedServer.State
    var path: String?

    init(state: ScriptedServer.State) { self.state = state }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let head) = unwrapInboundIn(data) else { return }
        path = head.uri
        guard let script = state.exchanges.withLock({ exchanges -> ScriptedServer.Script? in
            exchanges[head.uri]?.reached = true
            exchanges[head.uri]?.headers = Dictionary(
                    head.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }
                )
            return exchanges[head.uri]?.script
        }) else { context.close(promise: nil); return }
        guard !script.parks else { return }
        if !script.isHTTP {
            // Write exactly the scripted bytes, bypassing all HTTP framing.
            var raw = context.channel.allocator.buffer(capacity: script.chunks.reduce(0) { $0 + $1.count })
            for chunk in script.chunks { raw.writeBytes(chunk) }
            let bytes = raw
            let channel = context.channel
            context.pipeline.context(handlerType: HTTPResponseEncoder.self).whenSuccess { encoder in
                encoder.writeAndFlush(NIOAny(bytes)).whenComplete { _ in channel.close(promise: nil) }
            }
            return
        }
        var headers = HTTPHeaders(script.headers.map { ($0.key, $0.value) })
        headers.add(name: "Connection", value: "close")
        if let target = script.redirectsTo {
            headers.add(name: "Location", value: target.absoluteString)
            headers.add(name: "Content-Length", value: "0")
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .found, headers: headers))), promise: nil)
            finish(context)
            return
        }
        if script.declaresLength {
            // An explicit length lets scripts exercise replies that close before the promised body arrives.
            if !headers.contains(name: "Content-Length") {
                headers.add(name: "Content-Length", value: String(script.chunks.reduce(0) { $0 + $1.count }))
            }
        } else {
            headers.add(name: "Transfer-Encoding", value: "chunked")
        }
        let responseHead = HTTPResponseHead(version: .http1_1, status: .init(statusCode: script.status), headers: headers)
        context.writeAndFlush(wrapOutboundOut(.head(responseHead)), promise: nil)
        write(script, index: 0, context: context)
    }

    private func write(_ script: ScriptedServer.Script, index: Int, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        if index == script.stallsUntilStopped {
            // A broken cancellation must fail the assertion rather than hang the test indefinitely.
            var resumed = script
            resumed.stallsUntilStopped = nil
            let remaining = resumed
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.eventLoop.scheduleTask(in: .seconds(5)) {
                self.write(remaining, index: index, context: boundContext.value)
            }
            return
        }
        guard index < script.chunks.count else { finish(context); return }
        var buffer = context.channel.allocator.buffer(capacity: script.chunks[index].count)
        buffer.writeBytes(script.chunks[index])
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        if let path { state.exchanges.withLock { $0[path]?.delivered += 1 } }
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.eventLoop.scheduleTask(in: .nanoseconds(Int64(script.pace * 1_000_000_000))) {
            self.write(script, index: index + 1, context: boundContext.value)
        }
    }

    private func finish(_ context: ChannelHandlerContext) {
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let path { state.exchanges.withLock { $0[path]?.stopped = true } }
        context.fireChannelInactive()
    }
}
