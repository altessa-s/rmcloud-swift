// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The half of the root pointer this client reads and does not obey.
///
/// The pointer carries more than a hash and a generation. On a real account
/// both root paths answer with four fields — the two we act on, plus
/// `schemaVersion` and `deletedImmutableAction` — while `maxNetworkJobs`,
/// `hasMissingHashes` and `missingHashes` never appear at all. Firmware 3.29's
/// parser of the same body reads one more, `disableHTTP2` — the service's way
/// of turning a client off HTTP/2 — and it has not been seen on the wire yet.
///
/// **Nothing here is obeyed, and that is a decision rather than an omission.**
/// The schema is taken from the index's own first line, which is the more
/// direct source and the one that fails loudly. The concurrency hint would have
/// to be clamped to the ceiling this client already keeps, so following it
/// could only ever lower it — and it is not sent. The directive about deleted
/// immutable records asks for machinery this client does not have.
///
/// What it is read for is the day one of them changes. The service moves
/// `deletedImmutableAction` on the fly, and that field is an instruction about
/// **deletion** — while this client deletes for real: tombstones in the index,
/// and files in the mirror under Time Machine. Learning from a log line that
/// the service began saying something else is cheaper than learning it from
/// somebody whose files are gone.
struct RootAdvisory: Sendable, Equatable {
    var schemaVersion: Int?
    var deletedImmutableAction: String?
    var maxNetworkJobs: Int?
    var hasMissingHashes: Bool?
    var missingHashes: Int?
    /// Not obeyed either: the transport is the system's, and which protocol it
    /// speaks is negotiated below this client. Read so that the day the
    /// service starts asking is a line in the log.
    var disableHTTP2: Bool?

    /// Whether this is the ordinary state of every account we have seen, as
    /// opposed to the service doing something this client does not implement.
    ///
    /// Absent fields are ordinary: most of these have never been sent. So is a
    /// schema we can read and a directive we have seen directly — `rollback`
    /// comes from the server in lower case, and the other five names are
    /// known only in the spelling the client declares them in, so the
    /// comparison ignores case.
    var isOrdinary: Bool {
        let familiarSchema = schemaVersion.map { $0 == 3 || $0 == 4 } ?? true
        let familiarAction = deletedImmutableAction.map { action in
            Self.familiarActions.contains { $0.caseInsensitiveCompare(action) == .orderedSame }
        } ?? true
        return familiarSchema && familiarAction
            && maxNetworkJobs == nil
            && hasMissingHashes != true
            && (missingHashes ?? 0) == 0
            && disableHTTP2 != true
    }

    /// The two directives that ask nothing of a client which has no immutable
    /// records: leave it alone, or put back what was deleted — and this client
    /// deletes nothing it was not told to.
    private static let familiarActions = ["rollback", "none"]

    /// What is worth saying about this pointer, given the one seen before.
    ///
    /// Empty when nothing has changed: the root is read on every tick of the
    /// poller, and a line per read would bury the one that matters. A first
    /// sight — `previous` of `nil` — is described whole, because a process
    /// that has just started has said nothing yet.
    ///
    /// A field that has gone missing is a change like any other and is spelled
    /// out as one: a directive the service stops sending is exactly as
    /// informative as one it starts sending differently.
    func remarks(since previous: RootAdvisory?) -> [String] {
        guard let previous else { return description }
        guard self != previous else { return [] }
        var remarks: [String] = []
        if schemaVersion != previous.schemaVersion {
            remarks.append("schema \(Self.spell(previous.schemaVersion)) → \(Self.spell(schemaVersion))")
        }
        if deletedImmutableAction != previous.deletedImmutableAction {
            remarks.append(
                "deletedImmutableAction \(Self.spell(previous.deletedImmutableAction))"
                    + " → \(Self.spell(deletedImmutableAction))"
            )
        }
        if maxNetworkJobs != previous.maxNetworkJobs {
            remarks.append(
                "maxNetworkJobs \(Self.spell(previous.maxNetworkJobs)) → \(Self.spell(maxNetworkJobs))"
                    + " (not followed: this client keeps its own ceiling)"
            )
        }
        if hasMissingHashes != previous.hasMissingHashes || missingHashes != previous.missingHashes {
            remarks.append(missingHashesRemark)
        }
        if disableHTTP2 != previous.disableHTTP2 {
            remarks.append(
                "disableHTTP2 \(Self.spell(previous.disableHTTP2)) → \(Self.spell(disableHTTP2))"
                    + " (not followed: the system transport negotiates the protocol)"
            )
        }
        return remarks
    }

    /// Everything this pointer says, for the first sighting.
    private var description: [String] {
        var lines: [String] = []
        if let schemaVersion { lines.append("schema \(schemaVersion)") }
        if let deletedImmutableAction { lines.append("deletedImmutableAction \(deletedImmutableAction)") }
        if let maxNetworkJobs {
            lines.append("maxNetworkJobs \(maxNetworkJobs) (not followed: this client keeps its own ceiling)")
        }
        if hasMissingHashes == true || (missingHashes ?? 0) > 0 { lines.append(missingHashesRemark) }
        if let disableHTTP2 {
            lines.append("disableHTTP2 \(disableHTTP2) (not followed: the system transport negotiates the protocol)")
        }
        return lines
    }

    /// What the server says it is missing. The count and not the hashes: a
    /// list of them explains no more than its length does, and the length is
    /// what says whether anything is wrong.
    private var missingHashesRemark: String {
        guard hasMissingHashes == true || (missingHashes ?? 0) > 0 else {
            return "the server no longer reports missing hashes"
        }
        return "the server reports \(missingHashes.map(String.init) ?? "some") hashes it does not hold"
    }

    /// A value, or the fact that there was none. Two spellings rather than one
    /// generic: passing `String.init(describing:)` through a generic captures a
    /// metatype, which strict concurrency is right to object to.
    private static func spell(_ value: Int?) -> String {
        value.map { "\($0)" } ?? "nothing"
    }

    private static func spell(_ value: String?) -> String {
        value ?? "nothing"
    }

    private static func spell(_ value: Bool?) -> String {
        value.map { "\($0)" } ?? "nothing"
    }
}
