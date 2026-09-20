// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMCloud
import Synchronization

/// The three secrets, doubled.
///
/// A real store writes into the Keychain of whoever is running the tests, and what
/// it would write there are tokens.
///
/// `Mutex` provides `Sendable` without `@unchecked`.
///
/// `refusesDeletion` is the one failure worth acting out: forgetting a device
/// takes its token with it, and the order of those two — token first, state only
/// if the token went — is what stops a credential outliving every name we have
/// for it.
///
/// A copy of the double the application this package came out of keeps, narrowed
/// to this port: there is no `SecretKey` here, because the vocabulary of every
/// other secret an application might hold is exactly what the protocol stopped
/// needing to know.
final class InMemorySecrets: CloudSecretStoring {
    struct Refused: Error {}

    private let storage = Mutex<[CloudSecret: String]>([:])
    private let refusing = Mutex(false)

    init(_ initial: [CloudSecret: String] = [:]) {
        storage.withLock { $0 = initial }
    }

    var refusesDeletion: Bool {
        get { refusing.withLock { $0 } }
        set { refusing.withLock { $0 = newValue } }
    }

    func secret(_ which: CloudSecret) throws -> String? {
        storage.withLock { $0[which] }
    }

    func save(_ value: String, as which: CloudSecret) throws {
        storage.withLock { $0[which] = value }
    }

    func forget(_ which: CloudSecret) throws {
        if refusing.withLock({ $0 }) { throw Refused() }
        storage.withLock { $0[which] = nil }
    }
}
