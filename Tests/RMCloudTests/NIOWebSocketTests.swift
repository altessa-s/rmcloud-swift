// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

#if os(Linux) || os(Windows)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIO
@testable import RMCloud
import Testing

private func socketRequest(_ url: URL) throws -> URLRequest {
    var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    components.scheme = "ws"
    return URLRequest(url: try #require(components.url))
}

@Test("NIO completes the upgrade, preserves authorization and assembles fragmented messages")
func nioReceivesFragmentsAndPongs() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let url = server.expect(.init(chunks: [Data("hel".utf8), Data("lo".utf8)], webSocket: true))
    var request = try socketRequest(url)
    request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
    let socket = try await NIOWebSocketConnector().connect(to: request)
    defer { socket.cancel() }
    #expect(try await socket.receive() == .text("hello"))
    try await socket.ping()
    let headers = Dictionary(server.headers(url).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    #expect(headers["authorization"] == "Bearer test-token")
    #expect(headers["sec-websocket-version"] == "13")
    #expect(headers["upgrade"]?.lowercased() == "websocket")
    #expect(headers["connection"]?.lowercased().contains("upgrade") == true)
    #expect(headers["sec-websocket-key"].flatMap { Data(base64Encoded: $0) }?.count == 16)
}

@Test("NIO reports an HTTP refusal from connect", arguments: [401, 403, 429, 500])
func nioRefusesDuringConnect(_ status: Int) async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let url = server.expect(.init(status: status))
    let request = try socketRequest(url)
    let error = await #expect(throws: CloudError.self) {
        _ = try await NIOWebSocketConnector().connect(to: request)
    }
    #expect(error == CloudError.fromHTTP(HTTPURLResponse.fake(status, for: url)))
}

@Test("NIO waits for a pong and times out when the peer stops answering")
func nioPingRequiresPong() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let url = server.expect(.init(webSocket: true, pongLimit: 1))
    let socket = try await NIOWebSocketConnector(pingTimeout: .milliseconds(100)).connect(to: socketRequest(url))
    defer { socket.cancel() }
    await #expect(throws: URLError(.timedOut)) { try await socket.ping() }
}

@Test("NIO cancel is repeatable and releases a pending receive")
func nioCancellationReleasesReceive() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let url = server.expect(.init(webSocket: true))
    let socket = try await NIOWebSocketConnector().connect(to: socketRequest(url))
    let receiving = Task { try await socket.receive() }
    socket.cancel()
    socket.cancel()
    await #expect(throws: (any Error).self) { try await receiving.value }
}

@Test("NIO times out an unanswered upgrade in connect")
func nioHandshakeTimesOut() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let url = server.expect(.init(parks: true))
    let request = try socketRequest(url)
    await #expect(throws: CloudError.transport(code: URLError.timedOut.rawValue)) {
        _ = try await NIOWebSocketConnector(handshakeTimeout: .milliseconds(100)).connect(to: request)
    }
}

@Test("Cancelling connect closes an unanswered NIO upgrade")
func nioHandshakeCancellationClosesConnection() async throws {
    let server = try ScriptedServer()
    defer { server.stop() }
    let url = server.expect(.init(parks: true))
    let request = try socketRequest(url)
    let connecting = Task { try await NIOWebSocketConnector().connect(to: request) }
    await until("the upgrade request to arrive") { server.reached(url) }
    connecting.cancel()
    await #expect(throws: CancellationError.self) { try await connecting.value }
    #expect(await server.stops(url))
}
#endif
