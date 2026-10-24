// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// The network abstraction: it lets the client be run in tests without a
/// server.
public protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Download the body into a temporary file, reporting progress.
    ///
    /// The file passes into the caller's ownership: moving or deleting it is
    /// their business. Kept apart from `send` because originals run to
    /// hundreds of megabytes: memory is no place for them, and the bar next
    /// to the file in Finder should fill up as the bytes arrive rather than
    /// jump at the very end.
    func download(
        _ request: URLRequest,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse)

    /// The same download, refused the moment it runs past `limitBytes`.
    ///
    /// A ceiling has to be applied here and nowhere above, because here is the
    /// only place the bytes can still be stopped: a caller holding a finished
    /// file has already paid the disk for it. `blobFile` verifies the hash and
    /// deletes what does not match, which is integrity — it is not a limit,
    /// and the file path needs the same ceiling the memory path has.
    ///
    /// A second method rather than a parameter on the first, so that a double
    /// — which serves what the fixture wrote and has nothing to overrun — goes
    /// on answering the one it already answers.
    func download(
        _ request: URLRequest,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse)

    /// Send a file as the body, reporting progress.
    ///
    /// The mirror image of `download`, and there for the same reason: an
    /// uploaded original runs to hundreds of megabytes, and putting it in
    /// `httpBody` would hold every byte in memory at once — inside the file
    /// provider extension, which is the first thing the system kills when it
    /// wants memory back.
    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        onProgress: @escaping TransferProgress
    ) async throws -> (Data, HTTPURLResponse)
}

public extension HTTPTransporting {
    /// The default implementation goes through `send`. Doubles in tests have
    /// no need for the file path, yet they must answer both calls alike.
    func download(
        _ request: URLRequest,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await send(request)
        let url = try ScratchFile.write(data)
        onProgress(Int64(data.count), Int64(data.count))
        return (url, response)
    }

    /// The default keeps no ceiling of its own, and cannot: it ends up in
    /// `send`, where the bytes are in memory before anybody counts them, and
    /// measuring a file that is already written is the protection that is not
    /// one. Only a transport that watches the bytes arrive can refuse them,
    /// and that one overrides this.
    func download(
        _ request: URLRequest,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        try await download(request, onProgress: onProgress)
    }

    /// The default reads the file and goes through `send`, so a test double
    /// finds the bytes where it already looks for them — in `httpBody` —
    /// without implementing anything. That is fine for fixtures; the
    /// production transport overrides this precisely so real documents never
    /// take this path.
    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        onProgress: @escaping TransferProgress
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let body = try Data(contentsOf: file)
        request.httpBody = body
        let result = try await send(request)
        onProgress(Int64(body.count), Int64(body.count))
        return result
    }

    /// The shared reading of response codes. `unauthorizedAs` lets the caller
    /// say that for them a 401 means "wrong one-time code".
    ///
    /// `body` is the refusal's own words, from a caller that has them in hand.
    /// One status keeps them — a 402 says which of the plan's limits was met,
    /// and it is the only place the service explains itself — and a caller
    /// whose body went straight to a file may leave it out.
    func validate(
        _ response: HTTPURLResponse,
        body: Data? = nil,
        unauthorizedAs unauthorized: CloudError = .unauthorized
    ) throws {
        if let refusal = CloudError.fromHTTP(response, body: body, unauthorizedAs: unauthorized) {
            throw refusal
        }
    }
}

public struct URLSessionTransport: HTTPTransporting {
    /// Internal rather than private so that a test can ask what a transport
    /// nobody configured is running on. The configuration is the only part of
    /// this that can be checked without a server, and it is the part that
    /// decides whether the answers are written to disk.
    let session: URLSession

    public init(session: URLSession = requests) {
        self.session = session
    }

    /// Strip the response cache off a configuration, whoever it came from.
    ///
    /// Every session in this file is built through here, because the default
    /// configuration — and `URLSession.shared` with it — writes answered
    /// requests to `URLCache.shared`, on disk, in the host's container: on
    /// this Mac that grows to 20 MB and 686 entries over fifteen days,
    /// holding the reply to `token/json/2/user/new` — the user token in
    /// plain text — alongside the root index and every document index, which
    /// together are the shape of the library. Document bytes are not among
    /// them: they arrive through `download`, and download tasks do not fill
    /// `URLCache`.
    ///
    /// A protocol answer is worth nothing to read twice — the client asks for
    /// a root generation precisely to learn whether it changed — so nothing is
    /// lost by refusing the store, and the policy makes sure a stale copy from
    /// somewhere else cannot be served either. `URLSession.shared` cannot be
    /// mended in place: its `configuration` hands back a copy, so assigning to
    /// it changes nothing, and the only fix is to stop using it.
    static func withoutCache(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// The one session the small requests run on, and the default this
    /// transport is built with.
    ///
    /// Process-wide, so the connection pool is shared between the several
    /// hundred requests a sync makes — the only reason to reach for
    /// `URLSession.shared` here, and the whole of it.
    ///
    /// Public because it is named in a public initialiser's default argument,
    /// which the caller's module evaluates and so may only mention public
    /// things. Nothing outside is expected to reach for it.
    public static let requests = URLSession(
        configuration: withoutCache(.default),
        delegate: redirects,
        delegateQueue: nil
    )

    /// The delegate the small requests run under. It exists for one thing:
    /// `URLSession` follows a redirect without telling anybody, and a hop to
    /// storage that nobody can see is a hop nobody can suspect. Every redirect
    /// is still followed; what it may carry is `followRedirect`'s to say.
    private static let redirects = RedirectWatcher()

    /// The ceiling on a body read into memory.
    ///
    /// Everything on this path is one of the protocol's own small files: a
    /// root, an index, a metadata file, a token. The largest of them is the
    /// root index, and at about a hundred and twenty bytes to the record a
    /// library of ten thousand documents puts it near one megabyte. Originals
    /// never come this way — they go to `download`, into a file, precisely
    /// because they run to hundreds of megabytes.
    ///
    /// Thirty-two megabytes is therefore not a guess at what the server might
    /// send but a line drawn far past anything it ever has, so that a body
    /// which is not the protocol's at all cannot be carried upwards as if it
    /// were.
    public static let bodyLimit = 32 * 1024 * 1024

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            WireLog.sent(request)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudError.malformedResponse("response is not HTTP")
            }
            WireLog.received(http, body: data, for: request)
            // Checked after the read, which bounds what travels onwards rather
            // than what was allocated — and that is the whole of what it buys.
            // Refusing on the declared length before the body arrives takes a
            // delegate, and a delegate is set on a session rather than on a
            // request: these are several hundred small requests to a sync, and
            // giving each of them a session of its own to watch its length
            // would trade the connection reuse between all of them for a check
            // on a body that is a hundred and twenty bytes to the record.
            guard data.count <= Self.bodyLimit else {
                throw CloudError.oversizedResponse(bytes: data.count, limit: Self.bodyLimit)
            }
            return (data, http)
        } catch let error as URLError {
            WireLog.failed(error, for: request)
            throw transportFailure(error)
        }
    }

    /// How many connections all the downloads together may hold to one host.
    ///
    /// macOS's own default, and it only binds anything because the session
    /// below is shared: a `URLSession` keeps a pool of its own, so a session
    /// per download would leave every download alone in its pool and this
    /// number would describe a limit of one against one. Finder materialises
    /// a whole selection at once, which would be as many connections as
    /// documents.
    public static let maximumConnectionsPerHost = 6

    /// The one session every download runs on, and the delegate that sorts
    /// them out.
    ///
    /// Progress reports reach only the **session** delegate: on the task
    /// delegate that `download(for:delegate:)` accepts, the download methods
    /// are not called at all — a 20 MB download gets 250 progress reports
    /// through the session delegate and none through the task delegate, with
    /// the file equally intact either way. A session per download would buy
    /// the same reporting, but at the cost of the connection pool above: the
    /// delegate is fixed when the session is made, so sharing one session is
    /// the only way to keep both.
    ///
    /// Never invalidated, deliberately: it lives as long as the process, and
    /// the router holds no session, so the two do not keep each other alive.
    /// The `session` this transport was built with governs `send` and `upload`
    /// only; downloads share one pool per process, which is the whole point of
    /// this one.
    private static let router = DownloadRouter()
    static let downloads: URLSession = {
        let configuration = withoutCache(.default)
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        return URLSession(configuration: configuration, delegate: router, delegateQueue: nil)
    }()

    public func download(
        _ request: URLRequest,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        // `.max` rather than `bodyLimit`: this overload is what a caller asks
        // for when it has no size to quote, and refusing an original on the
        // ceiling meant for a metadata file would be worse than not refusing
        // one at all. The callers that know a size say so.
        try await download(request, limitBytes: .max, onProgress: onProgress)
    }

    public func download(
        _ request: URLRequest,
        limitBytes: Int64,
        onProgress: @escaping TransferProgress
    ) async throws -> (URL, HTTPURLResponse) {
        do {
            WireLog.sent(request)
            let (file, response) = try await Self.router.run(
                request,
                ceiling: DownloadCeiling(limitBytes: limitBytes),
                onProgress: onProgress,
                in: Self.downloads
            )
            WireLog.receivedFile(
                response,
                bytes: (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                for: request
            )
            return (file, response)
        } catch let error as URLError {
            WireLog.failed(error, for: request)
            throw transportFailure(error)
        }
    }

    /// Sending a file works the same way round: `uploadTask(with:fromFile:)`
    /// streams the body off disk, and the bytes sent are reported to the
    /// session delegate — hence a session of its own here.
    ///
    /// A session each stays here where it went for downloads, because the
    /// pool is only worth sharing where several run at once. Uploads come from
    /// the one writer, one document at a time; downloads are handed out by
    /// Finder in whatever number the user selected.
    public func upload(
        _ request: URLRequest,
        fromFile file: URL,
        onProgress: @escaping TransferProgress
    ) async throws -> (Data, HTTPURLResponse) {
        let sender = UploadSender(onProgress: onProgress)
        // `configuration` hands back a copy, so the cache is stripped off this
        // one and not off the session it was taken from. Stripped again rather
        // than inherited: the default session has none by now, but a session
        // handed in from outside is not this file's promise to keep, and the
        // answer to an upload is a metadata write's — the shape of the library
        // again.
        let session = URLSession(
            configuration: Self.withoutCache(session.configuration),
            delegate: sender,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            WireLog.sent(request)
            let (data, response) = try await sender.run(request, fromFile: file, in: session)
            WireLog.received(response, body: data, for: request)
            return (data, response)
        } catch let error as URLError {
            WireLog.failed(error, for: request)
            throw transportFailure(error)
        }
    }
}
