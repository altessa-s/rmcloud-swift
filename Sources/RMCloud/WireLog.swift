// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RedactLog
import Synchronization

/// The wire, written out: what went to the service and what came back.
///
/// Off unless asked for. The protocol is unofficial and its failures are
/// rarely a stack trace — a 400 with a sentence in the body, a header nobody
/// documented, a redirect to storage — and the only way to see one is to look
/// at the exchange itself. That is worth a switch, and it is worth nothing at
/// all if the switch has to be a build.
///
/// ```
/// RMCLOUD_WIRE_LOG=headers   the request and response lines, and every header
/// RMCLOUD_WIRE_LOG=bodies    the same, plus bodies that are text, JSON or XML
/// ```
///
/// **What never reaches it.** Credentials are masked wherever they appear —
/// `Authorization`, anything named like a token or a cookie — by the same
/// masking the rest of this project logs secrets through: a length and a short
/// digest, enough to tell two tokens apart and nowhere near enough to walk
/// back to either. A URL's query is dropped and counted instead, because a
/// signed storage URL carries its signature there. The auth exchange's
/// bodies are the tokens themselves, and are never printed at any level —
/// only counted.
///
/// **What does, at `bodies`.** The user's own words: a `.metadata` blob holds
/// the name of a document, and an index holds the shape of the library. That
/// is the point of the level — a body one cannot read explains nothing — and
/// it is why it is a second word rather than the same switch. The line saying
/// so is printed once, when the level is read.
public enum WireLog {
    /// Frozen, for the reason given on `CloudError`.
    @frozen
    public enum Level: String, Sendable, CaseIterable {
        case off
        case headers
        case bodies
    }

    /// What the environment asked for, read once.
    public static let level = Level(named: ProcessInfo.processInfo.environment[variable])

    public static let variable = "RMCLOUD_WIRE_LOG"

    static var isOn: Bool { level != .off }

    // MARK: - What is written

    static func sent(_ request: URLRequest) {
        guard isOn else { return }
        announceOnce()
        for line in describe(request, level: level) { write(line) }
    }

    static func received(
        _ response: HTTPURLResponse,
        body: Data?,
        for request: URLRequest
    ) {
        guard isOn else { return }
        for line in describe(response, body: body, for: request, level: level) { write(line) }
    }

    /// A body that never comes into memory. Its size is the whole of what can
    /// honestly be said about it, and dumping hundreds of megabytes of a PDF
    /// into a log would say less than that.
    static func receivedFile(
        _ response: HTTPURLResponse,
        bytes: Int64,
        for request: URLRequest
    ) {
        guard isOn else { return }
        for line in describe(response, body: nil, for: request, level: level) { write(line) }
        write("  ← body: \(bytes, .public) bytes into a file")
    }

    /// Redirects are followed by `URLSession` without a word, and this is the
    /// word. The protocol is known to answer a blob write with a signed
    /// storage URL, and a hop nobody sees is a hop nobody can suspect.
    static func redirected(from response: HTTPURLResponse, to request: URLRequest) {
        guard isOn else { return }
        write("→→ \(response.statusCode, .public) redirect to \(safe(request.url), .public)")
        for line in describe(request, level: level) { write(line) }
    }

    static func failed(_ error: any Error, for request: URLRequest) {
        guard isOn else { return }
        let failure = String(describing: error)
        write("←! \(method(of: request), .public) \(safe(request.url), .public) — \(failure, .public)")
    }

    // MARK: - What the lines say

    /// The request as lines. Pure, so that what is written can be held to
    /// without a server: this is the half where a mistake is a leaked token
    /// rather than a wrong answer.
    static func describe(_ request: URLRequest, level: Level) -> [LogMessage] {
        guard level != .off else { return [] }
        var lines: [LogMessage] = [
            "→ \(method(of: request), .public) \(safe(request.url), .public)",
        ]
        lines += headerLines(request.allHTTPHeaderFields, arrow: "  →")
        if let body = bodyLine(
            request.httpBody,
            contentType: request.value(forHTTPHeaderField: "content-type"),
            of: request,
            arrow: "  →",
            level: level
        ) {
            lines.append(body)
        }
        return lines
    }

    static func describe(
        _ response: HTTPURLResponse,
        body: Data?,
        for request: URLRequest,
        level: Level
    ) -> [LogMessage] {
        guard level != .off else { return [] }
        var lines: [LogMessage] = [
            "← \(response.statusCode, .public) \(method(of: request), .public) \(safe(request.url), .public)",
        ]
        lines += headerLines(
            response.allHeaderFields.reduce(into: [String: String]()) { headers, field in
                headers[String(describing: field.key)] = String(describing: field.value)
            },
            arrow: "  ←"
        )
        if let body = bodyLine(
            body,
            contentType: response.value(forHTTPHeaderField: "content-type"),
            of: request,
            arrow: "  ←",
            level: level
        ) {
            lines.append(body)
        }
        return lines
    }

    /// The one line about a body, in either direction, or none.
    ///
    /// Three answers, in order of what may be said: a credential exchange's
    /// body is counted and never printed, whichever way it travels; a body
    /// the level asks for and a person can read is printed; anything else is
    /// counted. Decided once because the request and the response used to
    /// decide it in two copies, and this is the half where a mistake is a
    /// printed token rather than a wrong answer.
    static func bodyLine(
        _ body: Data?,
        contentType: String?,
        of request: URLRequest,
        arrow: String,
        level: Level
    ) -> LogMessage? {
        if carriesCredentialBody(request.url) {
            guard let body, !body.isEmpty else { return nil }
            return "\(arrow, .public) body: \(body.count, .public) bytes (credential exchange — never printed)"
        }
        if let text = bodyText(body, contentType: contentType, level: level) {
            return "\(arrow, .public) body: \(text, .public)"
        }
        guard let body else { return nil }
        return "\(arrow, .public) body: \(body.count, .public) bytes"
    }

    /// A body, when it is one a person can read and the level asks for it.
    ///
    /// The types are named rather than guessed: the protocol answers with
    /// `text/plain` for its indexes and metadata, `application/json` for the
    /// root pointer and its refusals, and octet-stream for everything that is
    /// a document. Anything else is bytes, and bytes in a log are noise.
    static func bodyText(_ data: Data?, contentType: String?, level: Level) -> String? {
        guard level == .bodies, let data, !data.isEmpty else { return nil }
        guard isReadable(contentType) else { return nil }
        guard let text = String(data: data.prefix(bodyLimit), encoding: .utf8) else { return nil }
        let tail = data.count > bodyLimit ? "… (\(data.count) bytes in all)" : ""
        return text.replacingOccurrences(of: "\n", with: "\n     ") + tail
    }

    /// The auth exchange carries the credential in the body itself: the
    /// registration answer IS the device token and the renewal answer IS
    /// the user token, so header masking cannot help there.
    static func carriesCredentialBody(_ url: URL?) -> Bool {
        url?.path.contains("/token/json/") == true
    }

    static func isReadable(_ contentType: String?) -> Bool {
        guard let type = contentType?.lowercased() else { return false }
        return type.hasPrefix("text/")
            || type.contains("json")
            || type.contains("xml")
    }

    /// Headers, with anything that could be a credential masked.
    ///
    /// A denylist by name, and it is checked by prefix and by substring
    /// because the field is the server's to name: `Authorization` is ours to
    /// expect, `x-…-token` is not.
    static func headerLines(_ headers: [String: String]?, arrow: String) -> [LogMessage] {
        (headers ?? [:])
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { field, value in headerLine(field: field, value: value, arrow: arrow) }
    }

    /// One header, with the value carrying what may be done with it.
    ///
    /// The masking is a tag rather than a call: the facade holds the masker
    /// this process installed, and a value that left here already masked would
    /// have been masked by whichever masker this file happened to reach for.
    /// The scheme is split off and printed — telling a `Bearer` from a `Basic`
    /// in a log is worth having, and it is not the secret.
    static func headerLine(field: String, value: String, arrow: String) -> LogMessage {
        guard tag(for: field) == .secret else {
            return "\(arrow, .public) \(field, .public): \(value, .public)"
        }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else {
            return "\(arrow, .public) \(field, .public): \(value, .secret)"
        }
        return "\(arrow, .public) \(field, .public): \(parts[0], .public) \(parts[1], .secret)"
    }

    /// What may be done with a header's value, decided by its name.
    static func tag(for field: String) -> LogMessage.Tag {
        let name = field.lowercased()
        guard !plainFields.contains(name),
              secretFields.contains(where: { name.contains($0) })
        else { return .public }
        return .secret
    }

    /// A URL without its query. A signed storage URL carries the signature
    /// there, and a blob's own path is a hash — which is not a secret, and is
    /// the one thing worth reading in these lines.
    static func safe(_ url: URL?) -> String {
        guard let url else { return "<no url>" }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let count = parts.queryItems?.count ?? 0
        parts.query = nil
        let base = parts.string ?? url.absoluteString
        return count == 0 ? base : "\(base) (+\(count) query items)"
    }

    private static func method(of request: URLRequest) -> String {
        request.httpMethod ?? "GET"
    }

    private static let secretFields = ["authorization", "token", "cookie", "signature", "secret"]

    /// The named exceptions to the rule above, and they have to be named: the
    /// rule matches by substring so that a field nobody has met yet — the
    /// service names its own headers — is masked rather than missed. That
    /// closes over one header which is not a credential at all.
    /// `rm-token-ttl-hint` is a count of seconds until the user token expires,
    /// and it is one of the more useful numbers on the wire.
    private static let plainFields: Set<String> = ["rm-token-ttl-hint"]

    /// Enough of a body to read an answer in. The protocol's own files are
    /// small; anything past this is a document, and a document does not belong
    /// in a log at any length.
    static let bodyLimit = 4096

    // MARK: - Where the lines go

    /// Both the unified log and standard error, whenever the switch is on.
    ///
    /// Both, because the two readers of this are a signed extension nobody can
    /// attach a terminal to and a person running `rmctl`, who sees the unified
    /// log only by opening a second window. Standard error rather than
    /// standard output, by this project's rule: the answer of a command can be
    /// piped into a file, and its commentary must not land there.
    ///
    /// Unconditionally rather than only for a terminal, which is what this did
    /// at first: piping the run into `head` or a file is exactly what somebody
    /// debugging does, and it turned the log off in the one case it was asked
    /// for. `.public` is not an oversight either — a log that redacts what the
    /// switch was turned on to see is a switch that does nothing.
    private static func write(_ line: LogMessage) {
        Log.cloud.debug(line)
    }

    private static let announced = Mutex(false)

    /// Said once, at the first request: what is about to be written, and what
    /// of the user's own words is in it.
    private static func announceOnce() {
        let first = announced.withLock { seen -> Bool in
            defer { seen = true }
            return !seen
        }
        guard first else { return }
        write("wire log on (\(level.rawValue, .public)): credentials are masked, query strings dropped")
        if level == .bodies {
            write("wire log: bodies include document names and the shape of the library")
        }
    }
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
extension WireLog.Level {
    public static func == (lhs: WireLog.Level, rhs: WireLog.Level) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

extension WireLog.Level {
    /// What the variable means, including the spellings a person actually
    /// types. `1` is what a switch is set to when nobody has read the
    /// documentation, and it can only mean the lesser of the two.
    init(named value: String?) {
        switch value?.lowercased() {
        case "headers", "1", "true", "yes", "on": self = .headers
        case "bodies", "body", "full", "2": self = .bodies
        default: self = .off
        }
    }
}
