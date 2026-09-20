// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Bytes by hash, and nothing else.
///
/// Split out because whoever feeds a renderer wants exactly this: the two
/// ways of fetching a blob, with no root, no index and no way to write. A
/// drawing path that cannot name `putRoot` cannot call it by accident.
public protocol BlobFetching: Sendable {
    func blob(hash: String, name: String, verify: Bool) async throws -> Data

    func blobFile(
        hash: String,
        name: String,
        onProgress: @escaping TransferProgress
    ) async throws -> URL

    /// The same, with the length the caller's index record declares, so that a
    /// response running past it is stopped rather than diagnosed afterwards.
    /// An original goes to disk, and nothing above the transport can refuse
    /// bytes that have already landed there.
    func blobFile(
        hash: String,
        name: String,
        expecting size: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> URL
}

/// The cloud as the library talks to it: the root, the indexes, the blobs.
///
/// The production client is an actor with retries and tokens behind it.
/// Tests and the composition root pass this port so the packages above do
/// not have to name that actor.
public protocol CloudServing: BlobFetching {
    func root() async throws -> CloudRoot

    func index(hash: String, name: String) async throws -> DocumentIndex

    func rootIndex() async throws -> (root: CloudRoot, index: DocumentIndex)

    func upload(_ data: Data, name: String, contentType: String?) async throws -> String

    func upload(
        contentsOf file: URL,
        name: String,
        onProgress: @escaping TransferProgress
    ) async throws -> String

    /// The generation the server settled on. Discardable as on the client
    /// itself: a caller that has nothing else to write is done with it.
    @discardableResult
    func putRoot(hash: String, generation: Int64, broadcast: Bool) async throws -> Int64
}

public extension BlobFetching {
    func blob(hash: String, name: String) async throws -> Data {
        try await blob(hash: hash, name: name, verify: true)
    }

    func blobFile(hash: String, name: String) async throws -> URL {
        try await blobFile(hash: hash, name: name, onProgress: { _, _ in })
    }

    /// A double has no wire to overrun and no ceiling to keep — it hands back
    /// what the fixture wrote. The client that does talk to a server overrides
    /// this and keeps one.
    func blobFile(
        hash: String,
        name: String,
        expecting size: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> URL {
        try await blobFile(hash: hash, name: name, onProgress: onProgress)
    }
}

public extension CloudServing {
    func upload(_ data: Data, name: String) async throws -> String {
        try await upload(data, name: name, contentType: nil)
    }

    func upload(contentsOf file: URL, name: String) async throws -> String {
        try await upload(contentsOf: file, name: name, onProgress: { _, _ in })
    }

    @discardableResult
    func putRoot(hash: String, generation: Int64) async throws -> Int64 {
        try await putRoot(hash: hash, generation: generation, broadcast: true)
    }
}

extension CloudClient: CloudServing {}
