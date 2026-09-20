// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Synchronization

/// The upload sender: progress reports while the body goes out.
///
/// Built like `DownloadRouter` and for the same reasons — a delegate is the
/// only way `URLSession` reports progress, and every mutable field sits under
/// a `Mutex` so `Sendable` is honest here rather than asserted.
final class UploadSender: NSObject, URLSessionTaskDelegate, Sendable {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirect(response, to: request, on: task))
    }
    private typealias Outcome = CheckedContinuation<(Data, HTTPURLResponse), any Error>

    private let onProgress: TransferProgress
    private let waiting = Mutex<Outcome?>(nil)

    init(onProgress: @escaping TransferProgress) {
        self.onProgress = onProgress
        super.init()
    }

    func run(
        _ request: URLRequest,
        fromFile file: URL,
        in session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        // The completion handler carries the response; the delegate carries
        // the progress. Both are needed, and they do not conflict.
        let task = session.uploadTask(with: request, fromFile: file) { [self] data, response, error in
            if let error {
                finish(.failure(error))
            } else if let http = response as? HTTPURLResponse {
                finish(.success((data ?? Data(), http)))
            } else {
                finish(.failure(CloudError.malformedResponse("response is not HTTP")))
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.withLock { $0 = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Wake the waiter exactly once.
    private func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        let continuation = waiting.withLock { held -> Outcome? in
            defer { held = nil }
            return held
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}
