// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// Each raw value below is a Keychain account name on people's machines, not a
// by-product of a case name. The rule suggests dropping them precisely because
// the two agree today; dropping them would make the next rename of a case a
// silent change of account, and this is the only place the pairing is written
// down. `ConfigurationTests` pins all three.
// swiftlint:disable redundant_string_enum_value

/// The three secrets this protocol holds, and nothing else it might hold.
///
/// The application this package came out of has one store for every secret it
/// keeps — a Keychain wrapper with a key per item, including an integration's API
/// token and the bearer of a local listener. None of that is the protocol's
/// business, and a package that has to name that vocabulary to ask for a token is
/// a package that cannot leave. So the port is narrowed to what is actually
/// asked: three names, read, written and taken away.
///
/// **The raw values are a contract with what is already on people's machines.**
/// These strings are the Keychain accounts the tokens were written under, by
/// every version that has shipped. A rename does not fail to compile and does not
/// fail at run time — it reads nothing, finds no device token, and presents itself
/// to the user as an account that has quietly disconnected. Spelled out for that
/// reason, including where the string matches the case's own name.
/// Frozen, for the reason given on `CloudError`: this framework ships in lockstep
/// with whatever links it, and an exhaustive `switch` in a consumer is the point.
@frozen
public enum CloudSecret: String, Sendable, CaseIterable {
    /// The long-lived device token issued in exchange for a one-time code.
    case deviceToken = "deviceToken"
    /// The UUID the device is registered under; needed when registering again
    /// and for diagnostics.
    case deviceID = "deviceID"
    /// The short-lived user token, kept so that a second process — or the same
    /// one started again — does not have to buy another one.
    case userToken = "userToken"
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
extension CloudSecret {
    public static func == (lhs: CloudSecret, rhs: CloudSecret) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

/// Where the three live. A port, not a store: this package does not know what a
/// Keychain is, and the two hosts that use it disagree about the answer — one is
/// signed and shares an access group, the other is a command-line tool with a
/// service of its own.
///
/// A host does not write an adapter for this. Whatever it already keeps secrets in
/// conforms to this protocol as well, which is why every call that builds a
/// `TokenProvider` reads exactly as it did before the port existed.
///
/// Hence also the names. `read`/`write`/`delete` would have been the obvious three
/// and were tried: a store that answers both this protocol and the application's
/// own then has two overloads of each, and `secrets.write(token, for: .userToken)`
/// stops compiling — the leading dot could be either vocabulary's. It is ninety-odd
/// call sites, almost all of them in tests that are not about secrets at all, and
/// none of them would have been clearer for spelling out which enum it meant. So
/// the selectors here are distinct instead, and the ambiguity cannot arise.
public protocol CloudSecretStoring: Sendable {
    func secret(_ which: CloudSecret) throws -> String?
    func save(_ value: String, as which: CloudSecret) throws
    func forget(_ which: CloudSecret) throws
}
// swiftlint:enable redundant_string_enum_value
