// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Reading: the pointer, the indexes it leads to, and the blobs they name.
extension CloudClient {
    /// Reading the root. v4 is the current path — where the official desktop
    /// reads, and where the pointer says the whole of what it has to say — and
    /// v3 is the fallback for an account that answers only there.
    ///
    /// On a real account both paths answer 200 with the same body, down to
    /// the field. So the order is not about finding a working path but about
    /// which of two working ones to prefer, and the answer is the one the
    /// official client prefers.
    public func root() async throws -> CloudRoot {
        let settled = rootVersion
        if let settled {
            if let root = try await root(at: settled) { return root }
            // The path that answered before answers 404 now. Kept, it would
            // turn every read from here to the end of the process into
            // `noRootYet` on the strength of one path, while the other may
            // still be serving the account — so the choice is given up and
            // made again, on the path not yet asked.
            rootVersion = nil
        }
        for version in Self.rootReadOrder where version != settled {
            if let root = try await root(at: version) { return root }
        }
        // Only a 404 is caught in `root(at:)`; anything else has already left.
        // So reaching here means every path answered 404: the account has no
        // root, which is how a new one looks rather than how a broken one does.
        throw CloudError.noRootYet
    }

    /// The paths, in the order they are tried when none has answered yet.
    private static let rootReadOrder: [CloudEndpoints.RootVersion] = [.v4, .v3]

    /// The root as one path answers it, or `nil` when that path says 404.
    ///
    /// A 404 here is the one answer that is not a failure: it means "not on
    /// this path", and which path holds the pointer is exactly what the caller
    /// is finding out. Anything else is thrown as it came.
    private func root(at version: CloudEndpoints.RootVersion) async throws -> CloudRoot? {
        do {
            // `roothash` names the operation rather than a file, and it goes
            // on the read as well as on the write. Only the write is refused
            // without it; a read is served either way, on both hosts this
            // client can end up on. That tolerance is the reason to send it
            // rather than not to: it is undocumented, the official client
            // sends it here, and a header we omit because nothing has objected
            // yet is one the service can start objecting to in a release we do
            // not control.
            let data = try await authorizedData(
                for: await hosts().root(version),
                name: Self.rootHashName
            )
            let response = try JSONDecoder().decode(RootResponse.self, from: data)
            rootVersion = version
            note(response.advisory)
            return CloudRoot(hash: response.hash, generation: response.generation)
        } catch CloudError.http(status: 404, _) {
            return nil
        }
    }

    /// A blob by hash, with its contents verified: the server must not slip
    /// us the wrong thing, and a corrupted download must not quietly settle
    /// in the cache.
    ///
    /// `name` is mandatory: without the `rm-filename` header the server
    /// answers 400. For the root index it is `root.docSchema`, for everything
    /// else the record's `documentID`.
    /// `verify: false` skips the file-hash check. `index` needs that: the
    /// addressing hash may be the node hash, which cannot be computed until
    /// the bytes are parsed. A blob that fails its hash must still not reach
    /// a cache, a page or a document.
    public func blob(hash: String, name: String, verify: Bool = true) async throws -> Data {
        guard !hash.isEmpty else { throw CloudError.missingHash(name: name) }
        let data = try await authorizedData(for: await hosts().blob(hash: hash), name: name)
        let actual = ContentHash.blob(data)
        guard !verify || actual == hash else {
            throw CloudError.hashMismatch(expected: hash, actual: actual)
        }
        return data
    }

    /// A blob into a file, with progress reported. The file goes to the
    /// caller: moving or deleting it is their business.
    ///
    /// Needed where the blob is large: there is no reason to hold a
    /// quarter-gigabyte PDF in memory, and the bar next to the file in Finder
    /// should fill up as the bytes arrive. A retry after a failure starts the
    /// download over and the fraction rolls back to zero — that is more
    /// honest than standing still.
    public func blobFile(
        hash: String,
        name: String,
        onProgress: @escaping TransferProgress = { _, _ in }
    ) async throws -> URL {
        try await blobFile(hash: hash, name: name, expecting: 0, onProgress: onProgress)
    }

    /// The same, with the length the caller's record declares.
    ///
    /// The length is what turns the download into a bounded one, and it costs
    /// nothing to know: every index record carries a blob's hash and its size
    /// together. See `ceiling(forDeclared:)` for what is done with it, and for
    /// what happens when there is none.
    public func blobFile(
        hash: String,
        name: String,
        expecting size: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> URL {
        guard !hash.isEmpty else { throw CloudError.missingHash(name: name) }
        let file = try await authorizedDownload(
            for: await hosts().blob(hash: hash),
            name: name,
            limitBytes: Self.ceiling(forDeclared: size),
            onProgress: onProgress
        )
        // The hash is computed outside the actor: on hundreds of megabytes
        // that is noticeable work, and the whole client must not be held up
        // by it. A detached task inherits no cancellation, so the caller's is
        // handed over by hand: when the system abandons the download, the
        // hashing must not keep grinding through the file.
        let hashing = Task.detached { try ContentHash.blob(contentsOf: file) }
        let actual: String
        do {
            actual = try await withTaskCancellationHandler {
                try await hashing.value
            } onCancel: {
                hashing.cancel()
            }
        } catch {
            // The file is ours from the moment the download claimed it, and
            // nothing sweeps the temporary directory behind us. Hashing fails
            // on cancellation — which the file provider does freely, and which
            // this very method arranges to be quick about — and on I/O. Either
            // way an abandoned original is hundreds of megabytes left inside
            // the extension's container, which is the first place the system
            // looks when it wants disk or memory back.
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        guard actual == hash else {
            try? FileManager.default.removeItem(at: file)
            throw CloudError.hashMismatch(expected: hash, actual: actual)
        }
        return file
    }

    /// How many bytes a blob may write to disk before the download is refused.
    ///
    /// A declared length is not a guess: an index record carries the hash of a
    /// blob and its size in the same line, so a response running past it is
    /// not the blob that was asked for and would fail the hash check at the
    /// end regardless. Refusing while the bytes are still arriving is the same
    /// answer for less disk — and the disk is the extension's container, which
    /// is the first place the system looks when it wants space back.
    ///
    /// Nought means the caller has no record to quote: `rmctl` fetching a bare
    /// hash, a file whose size nobody carried down. Those fall back to the
    /// general ceiling, which is a line drawn far past anything the account
    /// can hold rather than a limit the protocol states — it documents none.
    static func ceiling(forDeclared size: Int64) -> Int64 {
        size > 0 ? size : blobSizeLimit
    }

    /// The ceiling on a blob whose size nobody declared.
    ///
    /// Twice the largest document this app will put on a tablet (500 MiB, and
    /// that limit exists because a tablet has to open what it is sent), and
    /// half the blob cache's own default: a blob past this has nowhere to live
    /// here even if it arrived whole.
    public static let blobSizeLimit: Int64 = 1024 * 1024 * 1024

    /// An index file by hash — by either hash the protocol addresses one with.
    ///
    /// **An index is vouched for by one of two hashes, and which one is not
    /// something we can predict.** Two real accounts show both:
    ///
    /// ```
    ///    account A   schema 4   index under the file hash
    ///    account B   schema 3   index under the node hash
    /// ```
    ///
    /// On B the root pointed at `1b56fec1…` while the bytes served hashed to
    /// `549fab79…`, and the SHA-256 over the children's hashes came to
    /// `1b56fec1…` exactly. Requiring the file hash made every such account
    /// unreadable and told the user the protocol had changed — which is how a
    /// brand new account looked to us.
    ///
    /// **Choosing by the account's sync scope would be wrong, and a live
    /// account's own record shows it rather than an argument.** Account B
    /// answers `sync:fox` while it has no subscription and `sync:tortoise` an
    /// hour later, once a trial is switched on — and its index stays
    /// addressed by the node hash throughout. The scope follows the plan; the
    /// layout does not follow the scope. A client that picked its rule from
    /// the scope would break the moment a user started or ended a trial.
    ///
    /// Accepting either keeps what the check is for: substituted or corrupted
    /// bytes match neither, because both hashes are computed from the bytes in
    /// hand.
    public func index(hash: String, name: String) async throws -> DocumentIndex {
        // Fetched without the file-hash check, because the node hash cannot be
        // computed before the index is parsed; the decoding holds the bytes
        // to either address. A fault of this index rather than of the
        // service, and it has to say so: a walk over the library skips a
        // broken document and stops on a broken connection, and it tells the
        // two apart by the error.
        let data = try await blob(hash: hash, name: name, verify: false)
        return try DocumentIndex.decode(data, addressedBy: hash, name: name)
    }

    /// The root and its index in one call.
    public func rootIndex() async throws -> (root: CloudRoot, index: DocumentIndex) {
        let root = try await root()
        return (root, try await index(hash: root.hash, name: Self.rootIndexName))
    }

    /// The name of the root index in the `rm-filename` header.
    public static let rootIndexName = "root.docSchema"

    /// The pointer as it arrives. Two fields are acted on; the rest are read
    /// so that a change in them can be noticed — see `RootAdvisory`.
    ///
    /// Every one of the five is optional because every one of them is: the v3
    /// body on some accounts carries the hash and the generation and nothing
    /// else, and three of these have never been seen on the wire at all.
    struct RootResponse: Decodable {
        let hash: String
        let generation: Int64
        var schemaVersion: Int?
        var deletedImmutableAction: String?
        var maxNetworkJobs: Int?
        var hasMissingHashes: Bool?
        var missingHashes: [String]?

        var advisory: RootAdvisory {
            RootAdvisory(
                schemaVersion: schemaVersion,
                deletedImmutableAction: deletedImmutableAction,
                maxNetworkJobs: maxNetworkJobs,
                hasMissingHashes: hasMissingHashes,
                missingHashes: missingHashes?.count
            )
        }
    }
}
