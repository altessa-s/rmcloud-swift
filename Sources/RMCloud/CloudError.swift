// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The protocol's errors. HTTP statuses and network failures become these
/// before they leave the package, so the UI never takes HTTP apart.
/// Cancellation is the exception: `URLError.cancelled` is rethrown unchanged
/// so the file provider can see the system's own abort (see `transportFailure`).
/// Frozen: this framework ships in lockstep with whatever links it, so there is no
/// ABI to protect — and an exhaustive `switch` over these cases in a consumer is
/// the point. The one place that translates them into a user-facing error must
/// break its build when a case is added, not fall into an `@unknown default` and
/// map a new failure onto whatever the default happened to be.
@frozen
public enum CloudError: Error, Sendable, Equatable {
    /// The device is not registered yet: there is no device token.
    case notRegistered
    /// The one-time code is wrong, expired or already used.
    case invalidOneTimeCode
    /// The token was rejected by the server.
    case unauthorized
    /// The reMarkable account has no tablet on it.
    ///
    /// On a real account, the exchange of a device token for a user token
    /// answers 400 while the account has no tablet, and the very same device
    /// token goes through the moment one is paired. Registration itself
    /// succeeds either way — it is this second step that refuses.
    ///
    /// Not to be confused with a rejected code (that is 401) or with a broken
    /// request: ours never changes, so on our side the only variable is the
    /// account.
    case accountWithoutTablet

    /// The account has no root yet: nothing has ever been synced to it.
    ///
    /// Both root paths answer 404, and that is not a failure — it is what a
    /// brand new account looks like. An account with a tablet paired but
    /// nothing synced answers 404 on `/sync/v3/root` and on `/sync/v4/root`,
    /// and the moment one page arrives from the tablet the root appears.
    /// Read as an error, the first screen of the product told the user the
    /// server had failed.
    case noRootYet
    /// An index schema version we cannot read.
    case unsupportedSchema(String)
    /// A line of the index does not parse.
    case malformedIndex(line: String, reason: String)
    /// The server's response does not match the expected shape.
    case malformedResponse(String)
    /// A blob's contents did not agree with its hash.
    case hashMismatch(expected: String, actual: String)
    /// Something was asked of the cloud on behalf of an item that has no hash
    /// — a file kept on this Mac, which the cloud has never heard of.
    ///
    /// Caught before the request rather than on the wire, because on the wire
    /// it does not look like a mistake: the path collapses to
    /// `sync/v3/files/` and the server answers a plain 404. On a real
    /// account, that 404 failed the whole mirror pass, every pass, over
    /// one `.zip` the tablet would not take, and it read as "no such
    /// document" rather than "we asked for nothing".
    case missingHash(name: String)
    /// Too many requests.
    case rateLimited(retryAfter: TimeInterval?)
    /// The account's plan does not cover what was asked for: 402.
    ///
    /// A code of its own because the official client gives it one — its
    /// failure category for a 402 is named after an inactive entry, and it is
    /// the one refusal whose body that client keeps rather than discards. Two
    /// readings fit what is known: an account with no right to sync at all, and
    /// a record the free tariff has stopped serving because nothing has touched
    /// it in fifty days. Neither is mended by asking again, and the sentence
    /// the server sends is the only thing that says which one happened — so it
    /// is carried here, for the log and for `rmctl`, rather than thrown away.
    ///
    /// Never seen on our accounts. That is why it is treated as the account's
    /// business and not one document's: see `isDocumentLocal`.
    case notOnThisPlan(detail: String)
    /// The root moved on under us: somebody else wrote it between our read
    /// and our write. Not a breakage but the protocol's ordinary way of
    /// serialising writers — the answer is to re-read the root, merge again
    /// and repeat.
    ///
    /// The status is carried so a log can tell 412 from a 409. The live
    /// server answers 412; 409 is treated the same in case another host does
    /// not.
    case rootConflict(status: Int)
    /// Any other unsuccessful response code. The request path is kept for
    /// diagnostics: unlike the headers, it holds no secrets.
    case http(status: Int, path: String)
    /// A write the server refused, carrying whatever it said about why.
    ///
    /// Separate from `http` because writing is new and the protocol is
    /// unofficial: a 400 here is a sentence to read, not a code to map. The
    /// body of a refusal explains what the server disliked, and throwing that
    /// away costs a round of guessing every time. Reads keep the leaner
    /// `http` — there the code is the whole story.
    case writeRejected(status: Int, detail: String)
    /// A network error. The `URLError` code is kept rather than a description
    /// with the URL: a document's hash may end up in the URL, and the logs are
    /// no place for it.
    case transport(code: Int)
    /// A request that would have asked the cloud about nothing.
    ///
    /// `check-files` is the one call whose question is a list, and the service
    /// answers an empty one with 400. That refusal is about the request and
    /// says nothing about any hash — which is precisely how it would be read
    /// coming back: as the endpoint's opinion of what it was asked. Ours to
    /// catch, like `missingHash`, because on the wire it does not look like our
    /// mistake.
    case nothingToAsk(call: String)
    /// A response too large to be one of the protocol's own.
    ///
    /// Everything read into memory here is a root, an index, a metadata file
    /// or a token, and the largest of them on a real account is under two
    /// megabytes. Originals never come this way — they go into a file.
    case oversizedResponse(bytes: Int, limit: Int)
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness
// the compiler derives — and that witness is internal, so it is absent from
// this module's symbol table when RMCloud is linked as a binary framework. A
// generic comparison still goes through the exported protocol witness and is
// fine; a concrete one — `error == .noRootYet`, with both types in view —
// resolves in a release build, where it is inlined, and fails to link in a
// debug one. Declaring `==` here puts the comparison behind an exported
// symbol, which costs nothing and keeps `@frozen`: a new case must still
// break a consumer's build rather than fall into an `@unknown default`.
extension CloudError {
    public static func == (lhs: CloudError, rhs: CloudError) -> Bool {
        switch (lhs, rhs) {
        case (.notRegistered, .notRegistered),
             (.invalidOneTimeCode, .invalidOneTimeCode),
             (.unauthorized, .unauthorized),
             (.accountWithoutTablet, .accountWithoutTablet),
             (.noRootYet, .noRootYet):
            true
        case let (.unsupportedSchema(left), .unsupportedSchema(right)): left == right
        case let (.malformedIndex(leftLine, leftReason), .malformedIndex(rightLine, rightReason)):
            leftLine == rightLine && leftReason == rightReason
        case let (.malformedResponse(left), .malformedResponse(right)): left == right
        case let (.hashMismatch(leftExpected, leftActual), .hashMismatch(rightExpected, rightActual)):
            leftExpected == rightExpected && leftActual == rightActual
        case let (.missingHash(left), .missingHash(right)): left == right
        case let (.rateLimited(left), .rateLimited(right)): left == right
        case let (.notOnThisPlan(left), .notOnThisPlan(right)): left == right
        case let (.rootConflict(left), .rootConflict(right)): left == right
        case let (.http(leftStatus, leftPath), .http(rightStatus, rightPath)):
            leftStatus == rightStatus && leftPath == rightPath
        case let (.writeRejected(leftStatus, leftDetail), .writeRejected(rightStatus, rightDetail)):
            leftStatus == rightStatus && leftDetail == rightDetail
        case let (.transport(left), .transport(right)): left == right
        case let (.nothingToAsk(left), .nothingToAsk(right)): left == right
        case let (.oversizedResponse(leftBytes, leftLimit), .oversizedResponse(rightBytes, rightLimit)):
            leftBytes == rightBytes && leftLimit == rightLimit
        default: false
        }
    }
}

/// What a `URLSession` failure is in the protocol's terms — and the one that is
/// no failure at all.
///
/// Everything the transports throw arrives as a `URLError`, cancellation
/// included: `-999` is what a task answers when it was called off, which here
/// means the caller's own task was cancelled and the cancellation handler
/// passed that on. Carrying it outwards as `CloudError.transport` would turn
/// it into the host's "offline" failure, so a `Progress` the system had itself
/// cancelled would come back to `fileproviderd` as "the server is
/// unreachable" — a retry the policy would run against a request nobody
/// wants any more, and an error over the user's own decision. The extension
/// knows a cancellation when it sees one: its `isCancellation` looks for
/// exactly this error, among two other shapes, and would no longer see it.
///
/// One function rather than the rule written at every catch: there are four
/// ways out of the two transports, and until now all four said the same wrong
/// thing about the same error.
func transportFailure(_ error: URLError) -> any Error {
    // Handed back as it came. Renaming it would only be another name for the
    // layers above to recognise, and they already know this one.
    error.code == .cancelled ? error : CloudError.transport(code: error.errorCode)
}

public extension CloudError {
    /// What an unsuccessful response code means in the protocol's terms, or
    /// `nil` when the code is a success.
    ///
    /// Optional rather than throwing because the two callers disagree about
    /// what a 2xx means: a request is done with it, while a websocket upgrade
    /// that failed anyway still has its own error to report. Only the caller
    /// can say, so the answer comes back as a value.
    ///
    /// `unauthorizedAs` lets the caller say that for them a 401 means "wrong
    /// one-time code".
    ///
    /// `body` is what came back with the refusal, where the caller has it. Only
    /// one status makes anything of it — see `notOnThisPlan` — and a caller
    /// whose body never came into memory is free to say nothing.
    static func fromHTTP(
        _ response: HTTPURLResponse,
        body: Data? = nil,
        unauthorizedAs unauthorized: CloudError = .unauthorized
    ) -> CloudError? {
        switch response.statusCode {
        case 200..<300:
            nil
        case 401, 403:
            unauthorized
        case 402:
            .notOnThisPlan(detail: detail(of: body))
        case 429:
            .rateLimited(
                retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            )
        default:
            .http(status: response.statusCode, path: response.url?.path() ?? "")
        }
    }

    /// What a refusal said about itself, as much of it as is worth keeping.
    ///
    /// Trimmed because an error page can run to kilobytes of HTML while the
    /// sentence that matters is at the front — the official client reads a
    /// hundred bytes of a 402 and no more. Empty where there was no body: the
    /// absence is reported as an absence rather than as an explanation.
    static func detail(of body: Data?) -> String {
        guard let body else { return "" }
        return String(decoding: body.prefix(detailLimit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How much of a refusal's body is kept.
    static let detailLimit = 500

    /// Whether this is the fault of the one document being read, rather than
    /// of the connection, the account or the service.
    ///
    /// The distinction decides whether a walk over the library may carry on.
    /// Debris from older versions of the service is real — a record pointing
    /// at an index that is not there, metadata that does not decode — and one
    /// such document must not hide the rest of the library. But a dropped
    /// connection, a rate limit or a 5xx says nothing whatever about the
    /// document, and counting it as a broken one turns a lost network into a
    /// library that looks almost empty. That picture is then written to the
    /// index as deletions, and the mirror under Time Machine deletes the files
    /// to match.
    var isDocumentLocal: Bool {
        switch self {
        case .unsupportedSchema, .malformedIndex, .hashMismatch, .missingHash:
            true
        // The record points at something the storage does not have. Every
        // other code is news about the service, not about the record.
        case .http(let status, _):
            status == 404
        // A 402 could be read either way, and the two readings differ in what
        // they cost. Called the record's own fault, a walk that met one on
        // every document would finish with a library that looked empty — and
        // that picture is written to the index as tombstones, which the mirror
        // under Time Machine then carries out on the files. Called the
        // account's, the pass stops and nothing is lost but the sync, which is
        // visible and mendable. On a code neither of our accounts has ever
        // produced, that is the side to be wrong on.
        case .notOnThisPlan:
            false
        case .notRegistered, .invalidOneTimeCode, .unauthorized,
             .accountWithoutTablet, .noRootYet, .malformedResponse,
             .rateLimited, .rootConflict, .writeRejected, .transport,
             .oversizedResponse, .nothingToAsk:
            false
        }
    }

    /// Whether the failure says the host we chose is not there at all.
    ///
    /// Narrower than "the network failed", and the narrowness is the point.
    /// Where this client sends its requests is a choice — the region host from
    /// the token's claim — and only these three answers are about that choice:
    /// the name does not resolve, or nothing accepts a connection on it. A
    /// device with no network answers `-1009` for every host equally, and
    /// reading that as "the region host is wrong" would move an account off
    /// its own host on the strength of a walk out of Wi-Fi range.
    var meansHostIsNotThere: Bool {
        guard case .transport(let code) = self else { return false }
        return Self.hostNotThereCodes.contains(code)
    }

    /// The three, as `URLError` numbers them: the name does not resolve, or
    /// nothing accepts a connection on it.
    private static let hostNotThereCodes: Set<Int> = [
        URLError.cannotFindHost.rawValue,
        URLError.cannotConnectToHost.rawValue,
        URLError.dnsLookupFailed.rawValue,
    ]
}
