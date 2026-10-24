// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// The download delegate: progress reports, ceilings and finished files, for
/// every download in the process.
///
/// A class is needed because `URLSession` reports through a delegate, and one
/// instance because the session is one — the reports are sorted out by
/// `taskIdentifier`, which is unique among a session's live tasks. All the
/// mutable state is under a `Mutex`, so `Sendable` here is honest, without
/// `@unchecked`.
///
/// Internal rather than private for the same reason as `session` above: this is
/// where the whole of the download lives — the ceiling, the progress and the
/// claim — and the only way a test reaches it is by handing it a session of its
/// own with a `URLProtocol` under it. `downloads` cannot be that session; it is
/// process-wide by design, and `URLProtocol.registerClass` does not reach a
/// session built from a configuration of its own — such a request goes to
/// DNS and comes back `-1003`.
final class DownloadRouter: NSObject, URLSessionDownloadDelegate, Sendable {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirect(response, to: request, on: task))
    }
    private typealias Outcome = CheckedContinuation<(URL, HTTPURLResponse), any Error>

    private struct Waiting {
        let ceiling: DownloadCeiling
        let onProgress: TransferProgress
        let outcome: Outcome
    }

    private let waiting = Mutex<[Int: Waiting]>([:])

    /// Download and wait. Cancellation of the task passes straight through:
    /// `URLSession` answers it with an error, and that is what we hand
    /// upwards.
    func run(
        _ request: URLRequest,
        ceiling: DownloadCeiling,
        onProgress: @escaping TransferProgress,
        in session: URLSession
    ) async throws -> (URL, HTTPURLResponse) {
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Filed before the task is started, so that no report can
                // arrive before there is anybody to hand it to.
                waiting.withLock {
                    $0[task.taskIdentifier] = Waiting(
                        ceiling: ceiling,
                        onProgress: onProgress,
                        outcome: continuation
                    )
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Wake one waiter exactly once: success comes from
    /// `didFinishDownloadingTo`, an error from `didCompleteWithError`, and on
    /// a successful download both are called.
    private func finish(_ task: Int, _ result: Result<(URL, HTTPURLResponse), any Error>) {
        let waiter = waiting.withLock { $0.removeValue(forKey: task) }
        waiter?.outcome.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // The continuation is deliberately left where it is: a copy of it
        // taken out here alongside the one in the table would be a second
        // chance to resume it, and resuming twice traps.
        let waiter = waiting.withLock { held -> (DownloadCeiling, TransferProgress)? in
            held[downloadTask.taskIdentifier].map { ($0.ceiling, $0.onProgress) }
        }
        guard let (ceiling, onProgress) = waiter else { return }
        if let refusal = ceiling.refusal(
            written: totalBytesWritten,
            expected: totalBytesExpectedToWrite
        ) {
            // Cancelling is what stops the bytes — a delegate cannot refuse a
            // download by returning — and it takes the part-written file with
            // it. The `didCompleteWithError` that the cancellation brings
            // along finds no waiter and does nothing.
            downloadTask.cancel()
            finish(downloadTask.taskIdentifier, .failure(refusal))
            return
        }
        onProgress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw CloudError.malformedResponse("response is not HTTP")
            }
            // The file lives only until this method returns — we claim it at
            // once.
            finish(downloadTask.taskIdentifier, .success((try ScratchFile.claim(location), response)))
        } catch {
            finish(downloadTask.taskIdentifier, .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        // Named, not logged: a wire-log write from this delegate deadlocks on
        // Linux, and the naming is what callers branch on.
        let named = (error as? URLError).map(transportFailure) ?? error
        finish(task.taskIdentifier, .failure(named))
    }
}
