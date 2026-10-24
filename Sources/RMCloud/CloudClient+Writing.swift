// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Writing: blobs up, and the one request that makes them the library.
extension CloudClient {
    /// Upload a blob.
    ///
    /// The hash is the answer rather than an argument: the storage is
    /// content-addressed, so the bytes decide where they land, and what comes
    /// back is what the index must point at.
    ///
    /// `name` is mandatory exactly as on reads — without `rm-filename` the
    /// server answers 400. Repeating the request is safe, which is why the
    /// ordinary retries stay on: the same bytes always land under the same
    /// hash, so a retry after a dropped connection cannot leave a second copy
    /// behind.
    /// **The key is the hash of the bytes, and it cannot be anything else.**
    /// Declaring another one — to store an index under its node hash, the way
    /// one live account is written — is refused: `400 {"message":"invalid
    /// hash"}`. Whatever writes such an account uses a different route than
    /// this one.
    public func upload(
        _ data: Data,
        name: String,
        contentType: String? = nil
    ) async throws -> String {
        let hash = ContentHash.blob(data)
        let url = await hosts().blob(hash: hash)
        try await withReauth { token in
            var request = blobPut(
                url,
                name: name,
                token: token,
                checksum: CRC32C.googHash(data),
                contentType: contentType ?? Self.contentType(forName: name)
            )
            request.httpBody = data
            let transport = transport
            try await attempt(url) {
                let (body, response) = try await transport.send(request)
                try Self.checkWrite(response, body: body, name: name, transport: transport)
            }
        }
        return hash
    }

    /// Upload a file from disk, reporting progress.
    ///
    /// The same request as `upload(_:name:)`, with one difference that runs
    /// all the way through it: the bytes are never held in memory. The hash
    /// and the checksum are both taken in chunks, and the body is streamed
    /// off disk — an uploaded original runs to hundreds of megabytes, and
    /// this path lives inside the file provider extension.
    ///
    /// The file is read three times over: to hash, to checksum, to send.
    /// That is deliberate. One pass would mean holding the document, and the
    /// disk is cheaper than the memory the system would kill us for. The first
    /// two passes happen off the actor — see `fingerprint(of:)`.
    public func upload(
        contentsOf file: URL,
        name: String,
        onProgress: @escaping TransferProgress = { _, _ in }
    ) async throws -> String {
        let (hash, checksum) = try await Self.fingerprint(of: file)
        let url = await hosts().blob(hash: hash)

        try await withReauth { token in
            // The same request as the in-memory path, built by the same
            // function. An index never comes this way — they are small and
            // built in memory — but two upload paths that decide a header
            // differently is how the one above came to disagree with the
            // protocol in the first place.
            let request = blobPut(
                url,
                name: name,
                token: token,
                checksum: checksum,
                contentType: Self.contentType(forName: name)
            )
            let transport = transport
            try await attempt(url) {
                let (body, response) = try await transport.upload(
                    request,
                    fromFile: file,
                    onProgress: onProgress
                )
                try Self.checkWrite(response, body: body, name: name, transport: transport)
            }
        }
        return hash
    }

    /// The PUT both uploads send, minus the body — which one path sets in
    /// memory and the other streams off disk.
    ///
    /// One function because the headers are the whole of what the storage
    /// checks a write by, and the two paths once decided one of them
    /// differently — see `contentType(forName:)` for how that went.
    private func blobPut(
        _ url: URL,
        name: String,
        token: String,
        checksum: String,
        contentType: String
    ) -> URLRequest {
        var request = authorizedRequest(for: url, name: name, token: token)
        request.httpMethod = "PUT"
        // Mandatory, and not the SHA-256 the rest of the protocol runs on:
        // the storage behind sync v3 is Google Cloud Storage and wants its
        // own CRC32C. Without it, a real account with the hash, the token and
        // `rm-filename` all correct still gets
        // `400 {"message":"missing checksum"}`.
        request.setValue(checksum, forHTTPHeaderField: CRC32C.header)
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        return request
    }

    /// The hash and the checksum of a file, taken off the actor.
    ///
    /// Both are full passes over the document — up to the five hundred
    /// megabytes an upload is allowed — and taken inline, before the first
    /// `await`, they would be passes the whole client stood still for: no
    /// download, no root read, nothing else this process asks of the cloud
    /// could be served while one upload combed through its file. `blobFile`
    /// hashes in a detached task for the same reason; this is the same rule
    /// on the writing side, and the reason is the same one the project states
    /// for parsing and rendering.
    ///
    /// One task for the two of them: they are consecutive reads of the same
    /// file with nothing to say to each other, and the caller wants both or
    /// neither. A detached task inherits no cancellation, so the caller's is
    /// handed over by hand — `ContentHash` and `CRC32C` both check it at every
    /// chunk, and a document nobody is waiting for any more must not go on
    /// being read.
    private static func fingerprint(of file: URL) async throws -> (hash: String, checksum: String) {
        let measuring = Task.detached {
            (
                hash: try ContentHash.blob(contentsOf: file),
                checksum: try CRC32C.googHash(contentsOf: file)
            )
        }
        return try await withTaskCancellationHandler {
            try await measuring.value
        } onCancel: {
            measuring.cancel()
        }
    }

    /// The response to a write, with the server's own explanation kept.
    ///
    /// A refusal here is read rather than mapped: writing is new, the
    /// protocol is unofficial, and a bare "400" costs a round of guessing
    /// that the body would have settled outright. 401 still goes through the
    /// shared path so that the token refresh keeps working.
    private static func checkWrite(
        _ response: HTTPURLResponse,
        body: Data,
        name: String,
        transport: any HTTPTransporting
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return
        // A 402 among them: what the plan will not cover it will not cover on
        // a write either, and a refusal that reads the same both ways is one
        // fewer thing for a caller to tell apart.
        case 401, 402, 403, 429:
            try transport.validate(response, body: body)
        default:
            let detail = CloudError.detail(of: body)
            // The name is part of the message: several different files go
            // up during one write, and "invalid doc schema" without saying
            // which one cost a round of guessing.
            throw CloudError.writeRejected(
                status: response.statusCode,
                detail: "\(name) — \(detail.isEmpty ? "(empty body)" : detail)"
            )
        }
    }

    /// The `check-files` probe: which of these blobs the server says it
    /// lacks. The status and the body come back as they arrived.
    ///
    /// Raw on purpose. The endpoint is unproven on our accounts, and a probe
    /// exists to show what the server answers, not what we can already make
    /// of it — the day the answer is understood, this becomes a method that
    /// returns the missing hashes and stops being called a probe.
    ///
    /// Here rather than in the debugging client, though. A second HTTP stack
    /// there meant no retry, no fresh token when one aged out mid-run, and a
    /// body assembled with `try?` — which would have posted nothing at all
    /// while the refusal read as the endpoint's opinion of the hashes.
    public func probeCheckFiles(_ hashes: [String]) async throws -> (status: Int, body: String) {
        // An empty list is answered 400, and that 400 is about the request
        // rather than about any hash — which is exactly how it would be read
        // coming back from a probe: as the endpoint's opinion of what it was
        // asked. Caught before the wire for the same reason `missingHash` is,
        // and it is reachable rather than theoretical: the caller builds its
        // list from the account's own root index, and a fresh account has no
        // entries to take three of.
        guard !hashes.isEmpty else { throw CloudError.nothingToAsk(call: Self.checkFilesCall) }
        let url = await hosts().syncHost.appending(path: "sync/v3/check-files")
        let body = try JSONEncoder().encode(["files": hashes])
        return try await withReauth { token in
            var request = authorizedRequest(for: url, name: nil, token: token)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            let transport = transport
            return try await attempt(url) {
                let (data, response) = try await transport.send(request)
                // The one status not reported but acted on: a token that aged
                // out is not an answer about hashes, and `withReauth` mends it
                // with a new one rather than with a printed 401.
                if response.statusCode == 401 { throw CloudError.unauthorized }
                return (response.statusCode, String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// What the probe above is called when it has to name itself in a failure.
    private static let checkFilesCall = "check-files"

    /// Point the root at a new index, and get the new generation back.
    ///
    /// `generation` is the one that came with the root this write was built
    /// on. The server accepts the write only while nobody else has moved the
    /// root since — that is the whole of the protocol's locking, and a
    /// refusal is routine rather than broken: re-read, merge again, repeat.
    ///
    /// Deliberately without retries, unlike `upload`. `attempt` repeats on
    /// 5xx and on network errors, and this is the one request where "it may
    /// already have gone through" is not an academic worry: a blind repeat
    /// could point the root at a tree built on a generation that has since
    /// stopped being current.
    @discardableResult
    public func putRoot(
        hash: String,
        generation: Int64,
        broadcast: Bool = true
    ) async throws -> Int64 {
        // Always v3, whatever answered the read. The two paths are not a pair
        // to be kept in step: the official client reads v4 and writes v3 on the
        // same account, and a PUT on v4 has never been seen on the wire at all.
        // Following the read here would mean that on every account whose
        // pointer is read from v4 — which is now every account we prefer to
        // read that way — the write would be a request whose reply nobody
        // has ever observed.
        let url = await hosts().rootWrite
        // A 429 is repeated, and only a 429. "Too many requests" means the
        // server did not take this one: nothing was applied, and waiting is
        // the whole remedy. A network error is a different matter — the
        // request may have gone through with the answer lost on the way back,
        // and a blind repeat would point the root at a tree built on a
        // generation that has stopped being current. For example, a write
        // refused with 429 while the root was being polled from another
        // process left the command simply failing in the user's hands.
        var attempt = 1
        while true {
            do {
                return try await putRootOnce(
                    url: url,
                    hash: hash,
                    generation: generation,
                    broadcast: broadcast
                )
            } catch CloudError.rateLimited(let after) where attempt < policy.maxAttempts {
                attempt += 1
                try await sleeper.sleep(for: policy.delay(beforeAttempt: attempt, retryAfter: after))
            }
        }
    }

    /// One attempt at the root write. The URL comes from the caller rather
    /// than being worked out here, so that a repeat goes exactly where the
    /// attempt it repeats went — the host is resolved, and a write is no place
    /// to discover it has moved.
    private func putRootOnce(
        url: URL,
        hash: String,
        generation: Int64,
        broadcast: Bool
    ) async throws -> Int64 {
        try await withReauth { token in
            var request = authorizedRequest(for: url, name: Self.rootHashName, token: token)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(
                RootUpdate(broadcast: broadcast, generation: generation, hash: hash)
            )

            let (data, response) = try await transport.send(request)
            if Self.conflictStatuses.contains(response.statusCode) {
                throw CloudError.rootConflict(status: response.statusCode)
            }
            try Self.checkWrite(response, body: data, name: Self.rootHashName, transport: transport)
            return try JSONDecoder().decode(RootResponse.self, from: data).generation
        }
    }

    /// What a blob goes up as, when the caller names nothing.
    ///
    /// The protocol decides it by the name, so this does too: **any**
    /// `.docSchema` is text and everything else is bytes. Decided here rather
    /// than at the call sites because there is no caller for whom it is
    /// optional — and because the one call site that had to remember forgot.
    /// The root index was given its type by hand and a document's index was
    /// not, so for as long as this volume has been able to write, every index
    /// under a document went up announced as octets.
    static func contentType(forName name: String) -> String {
        name.hasSuffix(indexNameSuffix) ? indexContentType : blobContentType
    }

    /// What makes a name an index rather than a file inside a document.
    public static let indexNameSuffix = ".docSchema"

    /// The content type every index is uploaded with — the root's and a
    /// document's alike. rmapi sends exactly this; on a protocol this
    /// unofficial, matching it is cheaper than discovering later that it
    /// mattered.
    public static let indexContentType = "text/plain; charset=UTF-8"

    /// And everything else: the originals, the metadata, the pages.
    public static let blobContentType = "application/octet-stream"

    /// The name the root write carries in `rm-filename`. Not the index's own
    /// name: this request writes the pointer, not the file.
    public static let rootHashName = "roothash"

    /// Which codes mean "somebody wrote the root before you". The live
    /// server answers 412; 409 is kept so another host cannot surprise us.
    private static let conflictStatuses: Set<Int> = [409, 412]

    /// The body of a root write. The field order follows rmapi's; JSON does
    /// not care, but a diff against the reference implementation should stay
    /// readable.
    private struct RootUpdate: Encodable {
        let broadcast: Bool
        let generation: Int64
        let hash: String
    }
}
