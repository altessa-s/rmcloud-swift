// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// One frame of the push channel, unwrapped.
///
/// The channel is pub-sub: what the tablet sent sits in `message.attributes`
/// and everything around it belongs to the transport. The unwrapping lives
/// here rather than at each caller — the poller wants the event name and
/// `rmctl watch` wants the whole frame, and two readings of one wrapper drift
/// apart without anyone noticing.
public struct NotificationEvent: Sendable {
    /// `SyncComplete` and the like.
    public let event: String?
    /// Which device caused it — its description when the server sends one,
    /// its identifier otherwise.
    public let device: String?
    /// The identifier of that device, as the service spells it.
    public let sourceDeviceID: String?
    /// Whether this Mac is what caused it.
    ///
    /// Our own writing comes back to us as a frame like any other, and acting
    /// on it costs a root read for a change we made and have already recorded
    /// — the writer updates the index itself, so that nothing waits on the
    /// channel. `false` whenever the answer is not certain: an unnamed device,
    /// a token that carries no claim, a service that attributes the frame some
    /// other way. Being told about our own change is a wasted request; missing
    /// somebody else's is a stale library.
    public let isFromThisDevice: Bool
    /// The document the event is about, when it names one.
    public let documentID: String?
    /// The document's name. The tablet spells the field with the double s
    /// (`vissibleName`); that is not a typo to fix.
    public let visibleName: String?
    /// Every attribute of the frame, as it arrived. Nothing is dropped: what
    /// the channel carries is precisely what a debugging run is here to look
    /// at, and a field we have never seen is one we would otherwise never
    /// learn about.
    public let attributes: [String: String]
    /// The frame as it arrived, kept whole.
    ///
    /// The parsed fields are `message.attributes` and nothing else — the
    /// wrapper around them, `messageid`, `data`, and whatever the next
    /// generation of the service adds, are outside it. A watcher exists to
    /// see those, and a parser that keeps only what it understands is a
    /// parser that hides everything new.
    public let frame: NotificationFrame

    /// The event as one of the words the protocol uses, or `nil` for one it
    /// does not — a firmware newer than this build is allowed to invent them.
    public var kind: NotificationKind? {
        event.flatMap(NotificationKind.init(rawValue:))
    }

    /// Whether this frame is about the library at all.
    ///
    /// Only `SyncComplete` is. The channel also carries the search index, the
    /// integrations and the tablet's passcode, and re-reading the root for
    /// those spends a request on an answer that cannot have changed — on a
    /// live account, for example, a minute of work on the tablet gives five
    /// `SyncComplete` and one `SearchIndexUpdated`.
    ///
    /// An unknown word is **not** a library change either. That is the whole
    /// of the risk this rule carries: if the service renames the event, push
    /// stops waking the poller and the library falls back to being polled on
    /// its interval — late rather than wrong, and visible in the log, because
    /// an unknown word is written down when it arrives.
    public var changesLibrary: Bool { kind == .syncComplete }

    /// Best-effort on purpose: a wake never depended on reading the contents,
    /// so an unparsed frame is a fact to report, not a failure to raise.
    ///
    /// `ownDevice` is this client's own identifier, when the caller knows it —
    /// the stream reads it off the token it connected with. Absent, every frame
    /// is somebody else's, which is what a watcher wants and what the reader of
    /// a single frame has no way to dispute.
    public init?(frame: NotificationFrame, ownDevice: String? = nil) {
        guard let root = (try? JSONSerialization.jsonObject(with: frame.data)) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let payload = message["attributes"] as? [String: Any]
        else { return nil }

        // Values are strings on the wire. One that is not gets its
        // description rather than the silent treatment: a number where a
        // string was expected is news.
        self.frame = frame
        attributes = payload.mapValues { $0 as? String ?? String(describing: $0) }
        event = attributes["event"]
        let source = attributes["sourceDeviceID"]
        sourceDeviceID = source
        device = attributes["sourceDeviceDesc"] ?? source
        // Compared only when both sides are there: two absences would
        // otherwise agree with each other and make every frame our own, which
        // is the one mistake here that loses changes.
        isFromThisDevice = ownDevice != nil && ownDevice == source
        // Both spellings, because the service uses both: the passcode events
        // name the resource `ID` where the document events call it `id`.
        documentID = attributes["id"] ?? attributes["ID"]
        visibleName = attributes["vissibleName"]
    }
}

/// The events this channel carries, as the protocol names them.
///
/// Six words, and only the first is about the library. The rest belong to
/// parts of the service this product does not implement: the cloud search
/// index, the third-party storage integrations, the passcode on the tablet.
///
/// A word outside this list is `nil` rather than a failure. The vocabulary was
/// read off a client, not out of a contract, and the service is free to add to
/// it — what an unknown word means is a decision for whoever is listening, not
/// for the parser.
/// Frozen, for the reason given on `CloudError`: this framework ships in lockstep
/// with whatever links it, and an exhaustive `switch` in a consumer is the point.
@frozen
public enum NotificationKind: String, Sendable, CaseIterable {
    case syncComplete = "SyncComplete"
    case searchIndexUpdated = "SearchIndexUpdated"
    case integrationsUpdated = "IntegrationsUpdated"
    case passcodeReset = "PasscodeReset"
    case passcodeResetApproved = "PasscodeResetApproved"
    case passcodeResetDenied = "PasscodeResetDenied"
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness
// the compiler derives — and that witness is internal, so it is absent from
// this module's symbol table when RMCloud is linked as a binary framework.
// The reference resolves in a release build, where the comparison is inlined,
// and fails to link in a debug one. Declaring `==` here puts the comparison
// behind an exported symbol, which costs nothing and keeps `@frozen`: a new
// case must still break a consumer's build rather than fall into an
// `@unknown default`.
extension NotificationKind {
    public static func == (lhs: NotificationKind, rhs: NotificationKind) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

/// What the stream tells its owner.
///
/// More than "something happened", because the two owners want different
/// things: the app wakes its poller and ignores the rest, while a person
/// watching the channel needs to see the socket come up and go down —
/// visibility a connection running on its own, with neither reconnects nor a
/// fresh token, would never carry.
/// Frozen, for the reason given on `CloudError`: this framework ships in lockstep
/// with whatever links it, and an exhaustive `switch` in a consumer is the point.
@frozen
public enum NotificationSignal: Sendable {
    /// The socket is up. Sent again after every reconnect.
    case connected
    /// A frame arrived and read.
    case event(NotificationEvent)
    /// A frame arrived whose wrapper did not parse. It still means the
    /// account changed — the contents were never what the wake rested on.
    ///
    /// The frame itself rather than its size: a shape we cannot read is the
    /// most interesting thing this channel can deliver, and a byte count is
    /// the one fact about it that explains nothing.
    case unreadableFrame(NotificationFrame)
    /// The socket went down. Routine: sleep, a change of network, a user
    /// token that aged out.
    ///
    /// The error itself, not a sentence about it. Wording belongs to whoever
    /// prints — `rmctl` turns a `CloudError` into advice a person can act on,
    /// while this module would only have had `String(describing:)` to offer,
    /// which is how a raw `NSError` came to be what a watcher saw.
    ///
    /// `any Error` and not `any Error & Sendable`: in Swift 6 the first
    /// already implies the second, and the compiler says so — the spelling
    /// with both was a cast that always succeeded.
    case dropped(any Error)
}
