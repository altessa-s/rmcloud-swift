// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RMCloud
import Testing

private actor UploadRetryTransport: HTTPTransporting {
    var writes = 0
    let status: Int
    let failures: Int

    init(status: Int, failures: Int = 1) {
        self.status = status
        self.failures = failures
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "PUT" else {
            return (Data("test-user-token".utf8), .fake(for: request))
        }
        writes += 1
        if writes <= failures {
            return (Data("temporarily unavailable".utf8), .fake(status, for: request))
        }
        return (Data(#"{"generation":2}"#.utf8), .fake(for: request))
    }
}

private func retryClient(_ transport: UploadRetryTransport, sleeper: RecordingSleeper) -> CloudClient {
    let tokens = TokenProvider(transport: transport, secrets: InMemorySecrets([.deviceToken: "device"]))
    return CloudClient(transport: transport, tokens: tokens, sleeper: sleeper)
}

@Test("Blob uploads retry server failures in both upload paths", arguments: [500, 503, 599], [false, true])
func uploadsRetryServerFailures(status: Int, fromFile: Bool) async throws {
    let transport = UploadRetryTransport(status: status)
    let sleeper = RecordingSleeper()
    let client = retryClient(transport, sleeper: sleeper)
    let payload = Data("payload".utf8)
    let hash: String
    if fromFile {
        let file = FileManager.default.temporaryDirectory.appending(path: "upload-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try payload.write(to: file)
        hash = try await client.upload(contentsOf: file, name: "test.pdf")
    } else {
        hash = try await client.upload(payload, name: "test.pdf")
    }
    #expect(hash == ContentHash.blob(payload))
    #expect(await transport.writes == 2)
    #expect(sleeper.delays.count == 1)
}

@Test("Permanent upload refusals are not retried", arguments: [400, 422])
func uploadRefusalsAreNotRetried(status: Int) async {
    let transport = UploadRetryTransport(status: status)
    let sleeper = RecordingSleeper()
    let client = retryClient(transport, sleeper: sleeper)
    await #expect(throws: CloudError.writeRejected(status: status, detail: "test.pdf — temporarily unavailable")) {
        _ = try await client.upload(Data(), name: "test.pdf")
    }
    #expect(await transport.writes == 1)
    #expect(sleeper.delays.isEmpty)
}

@Test("Exhausted upload retries retain the server's explanation")
func exhaustedUploadRetries() async {
    let transport = UploadRetryTransport(status: 503, failures: 10)
    let sleeper = RecordingSleeper()
    let client = retryClient(transport, sleeper: sleeper)
    await #expect(throws: CloudError.writeRejected(status: 503, detail: "test.pdf — temporarily unavailable")) {
        _ = try await client.upload(Data(), name: "test.pdf")
    }
    #expect(await transport.writes == 3)
    #expect(sleeper.delays.count == 2)
}

@Test("Root writes still do not retry an ambiguous server failure")
func rootServerFailureIsNotRetried() async {
    let transport = UploadRetryTransport(status: 503)
    let sleeper = RecordingSleeper()
    let client = retryClient(transport, sleeper: sleeper)
    await #expect(throws: CloudError.writeRejected(status: 503, detail: "roothash — temporarily unavailable")) {
        _ = try await client.putRoot(hash: "hash", generation: 1)
    }
    #expect(await transport.writes == 1)
    #expect(sleeper.delays.isEmpty)
}
