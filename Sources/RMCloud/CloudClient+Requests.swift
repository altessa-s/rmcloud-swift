// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RedactLog

/// What every request above is made of: a token that may have to be bought
/// again, a header the protocol demands, and a retry that knows what is worth
/// repeating.
extension CloudClient {
    /// One repeat attempt after a 401: a user token lives less than a day
    /// and can expire right in the middle of a walk over the tree. Shared by
    /// the memory and the file paths, so the two cannot drift in how they
    /// treat authorization.
    ///
    /// The token is fetched here and handed to the attempt rather than looked
    /// up inside it, because a refusal has to name the token it was refused
    /// for. Asking the provider to discard "the current one" is asking a
    /// different question: this client is an actor and the host runs its
    /// requests side by side, so between a 401 going out and coming back the
    /// provider may already hold a replacement bought by the request next door.
    func withReauth<T>(_ operation: (String) async throws -> T) async throws -> T {
        let token = try await tokens.userToken()
        do {
            return try await operation(token)
        } catch CloudError.unauthorized {
            await tokens.invalidateUserToken(token)
            return try await operation(try await tokens.userToken())
        }
    }

    func authorizedData(for url: URL, name: String? = nil) async throws -> Data {
        try await withReauth { try await send(url, name: name, token: $0) }
    }

    /// The same thing, but the response lands in a file.
    func authorizedDownload(
        for url: URL,
        name: String?,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> URL {
        try await withReauth { token in
            try await downloadFile(
                url,
                name: name,
                token: token,
                limitBytes: limitBytes,
                onProgress: onProgress
            )
        }
    }

    /// One GET with retries according to the policy. Only the network, 5xx
    /// and `Retry-After` are repeated; a 401 does not reach here —
    /// `authorizedData` deals with it, because it is fixed by a new token
    /// rather than by waiting.
    private func send(_ url: URL, name: String?, token: String) async throws -> Data {
        let request = authorizedRequest(for: url, name: name, token: token)
        let transport = transport
        return try await attempt(url) {
            let (data, response) = try await transport.send(request)
            // The body is offered along with the code: a refusal on this path
            // has already been read into memory, and one status makes a
            // sentence of it rather than a number.
            try transport.validate(response, body: data)
            return data
        }
    }

    /// The same GET, but written into a file. An error response arrives with
    /// a body too — we have no use for it, and we clean the file up after
    /// ourselves.
    private func downloadFile(
        _ url: URL,
        name: String?,
        token: String,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> URL {
        let request = authorizedRequest(for: url, name: name, token: token)
        let transport = transport
        return try await attempt(url) {
            let (file, response) = try await transport.download(
                request,
                limitBytes: limitBytes,
                onProgress: onProgress
            )
            do {
                // A refusal lands in the file like anything else, and on this
                // path the file is all there is. Read only when the answer is
                // not a success — a document runs to hundreds of megabytes and
                // is never what the sentence is in.
                try transport.validate(response, body: Self.refusalBody(response, in: file))
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            return file
        }
    }

    /// The front of a downloaded body, when the download was a refusal.
    ///
    /// `nil` for anything that succeeded, which is what keeps this off the
    /// path an original takes.
    private static func refusalBody(_ response: HTTPURLResponse, in file: URL) -> Data? {
        guard !(200..<300).contains(response.statusCode) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: CloudError.detailLimit)
    }

    /// A GET with the token and the protocol's headers. `rm-filename` is
    /// mandatory on every blob request: without it the server answers 400.
    ///
    /// The token is an argument rather than something fetched here, so that
    /// `withReauth` knows which one went out and can name it if it comes back
    /// refused.
    func authorizedRequest(for url: URL, name: String?, token: String) -> URLRequest {
        var request = ProtocolRequest.to(url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let name {
            request.setValue(name, forHTTPHeaderField: "rm-filename")
        }
        return request
    }

    /// Where this request goes. One line, because the answer may move: the
    /// region host is named by the token, and the token is bought afresh.
    func hosts() async -> CloudEndpoints {
        await resolver.endpoints()
    }

    /// Retries according to the policy, and one log line per failure.
    func attempt<T: Sendable>(
        _ url: URL,
        operation: sending () async throws -> T
    ) async throws -> T {
        do {
            return try await withRetry(policy: policy, sleeper: sleeper, operation: operation)
        } catch let error as CloudError {
            // The path and the code are not secrets, unlike the headers and
            // the body.
            Log.cloud.error("request failed: \(url.path(), .public) — \(String(describing: error), .public)")
            // A host that is not there is not the same failure as a network
            // that is away, and only the first one is about where we chose to
            // go. The retries are already spent by here, so this fires on a
            // host that stayed unreachable — and the resolver takes it once
            // per process.
            if error.meansHostIsNotThere { await resolver.syncHostFailed() }
            throw error
        }
    }
}
