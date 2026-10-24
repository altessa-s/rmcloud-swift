// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RMCloud
import Synchronization
import Testing

// What a blob download was allowed to cost. The path into memory has been
// bounded since it was written — `URLSessionTransport.bodyLimit`, checked on
// every `send` — and the path onto disk, which is the one originals take, was
// bounded by nothing at all: `blobFile` verified the hash of a file that had
// already been written whole, and deleted it afterwards. That is integrity,
// and it is not a limit: a response that keeps arriving fills the extension's
// container first and is refused second.

// MARK: - The rule

@Test("A ceiling refuses the bytes that arrived, whatever was declared")
func aCeilingRefusesTheBytesThatArrived() {
    let ceiling = DownloadCeiling(limitBytes: 100)

    #expect(ceiling.refusal(written: 100, expected: 100) == nil)
    #expect(
        ceiling.refusal(written: 101, expected: 100)
            == .oversizedResponse(bytes: 101, limit: 100)
    )
    // A length nobody declared arrives negative, and says nothing either way:
    // what is counted then is only what turned up.
    #expect(ceiling.refusal(written: 99, expected: -1) == nil)
    #expect(
        ceiling.refusal(written: 200, expected: -1)
            == .oversizedResponse(bytes: 200, limit: 100)
    )
}

// The declared length is worth reading for one reason: the refusal lands on the
// first report rather than after a ceiling's worth of bytes has gone to disk.
@Test("A declared length past the ceiling is refused before the bytes arrive")
func aCeilingRefusesADeclaredLengthAtOnce() {
    #expect(
        DownloadCeiling(limitBytes: 100).refusal(written: 1, expected: 4096)
            == .oversizedResponse(bytes: 4096, limit: 100)
    )
}

@Test("A blob nobody declared a size for still has a ceiling")
func anUndeclaredSizeFallsBackToTheGeneralCeiling() {
    #expect(CloudClient.ceiling(forDeclared: 0) == CloudClient.blobSizeLimit)
    #expect(CloudClient.ceiling(forDeclared: -1) == CloudClient.blobSizeLimit)
    #expect(CloudClient.ceiling(forDeclared: 4096) == 4096)
}

// MARK: - That the rule is reached

/// A transport that keeps the ceiling it was handed, the way the production one
/// does, and remembers what it was.
///
/// The point of it is the wiring rather than the rule: the rule is tested
/// above, and what cannot be seen from there is whether the size an index
/// record declared ever reaches the transport at all.
private final class MeteredTransport: HTTPTransporting {
    private let body: Data
    private let ceilings = Mutex<[Int64]>([])

    init(body: Data) {
        self.body = body
    }

    /// Every ceiling a download was asked to keep, in order.
    var kept: [Int64] { ceilings.withLock { $0 } }

    /// Only the token exchange comes this way — a blob goes to `download`.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data("user-token".utf8), Self.ok(request))
    }

    func download(
        _ request: URLRequest,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        ceilings.withLock { $0.append(limitBytes) }
        guard Int64(body.count) <= limitBytes else {
            throw CloudError.oversizedResponse(bytes: body.count, limit: Int(clamping: limitBytes))
        }
        let file = try ScratchFile.write(body)
        onProgress(Int64(body.count), Int64(body.count))
        return (file, Self.ok(request))
    }

    func download(
        _ request: URLRequest,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        // Never reached through `blobFile`, which always names a ceiling. Here
        // so that a day when it stops doing so is a failure rather than a
        // download with no limit on it.
        throw CloudError.malformedResponse("a download was asked for without a ceiling")
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse.fake(for: request)
    }
}

private func meteredClient(_ transport: MeteredTransport) throws -> CloudClient {
    let secrets = InMemorySecrets()
    try secrets.save("device-token", as: .deviceToken)
    return CloudClient(
        transport: transport,
        tokens: TokenProvider(transport: transport, secrets: secrets)
    )
}

@Test("The size a record declared is the ceiling the download is held to")
func aDeclaredSizeBecomesTheDownloadCeiling() async throws {
    let payload = Data("the contents of an original".utf8)
    let transport = MeteredTransport(body: payload)
    let client = try meteredClient(transport)

    let file = try await client.blobFile(
        hash: ContentHash.blob(payload),
        name: "doc.pdf",
        expecting: Int64(payload.count),
        onProgress: { _, _ in }
    )
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(try Data(contentsOf: file) == payload)
    #expect(transport.kept == [Int64(payload.count)])
}

@Test("A response running past the declared size is refused rather than written out")
func aResponsePastTheDeclaredSizeIsRefused() async throws {
    let payload = Data(repeating: 7, count: 4096)
    let transport = MeteredTransport(body: payload)
    let client = try meteredClient(transport)

    await #expect(throws: CloudError.oversizedResponse(bytes: 4096, limit: 10)) {
        _ = try await client.blobFile(
            hash: ContentHash.blob(payload),
            name: "doc.pdf",
            expecting: 10,
            onProgress: { _, _ in }
        )
    }
}

@Test("A caller with no size to quote still downloads under a ceiling")
func aBlobWithoutADeclaredSizeIsStillBounded() async throws {
    let payload = Data("a blob fetched by hash alone".utf8)
    let transport = MeteredTransport(body: payload)
    let client = try meteredClient(transport)

    let file = try await client.blobFile(hash: ContentHash.blob(payload), name: "doc.pdf")
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(transport.kept == [CloudClient.blobSizeLimit])
}
