// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The root of the tree: the index hash and the generation for optimistic
/// locking.
///
/// A value of its own rather than a type nested in the client. `CloudServing`
/// exists so that the packages above never have to name that actor, and while
/// the root was spelled `CloudClient.Root` every one of them did — the sync,
/// the doubles in two test bundles, `rmctl`. A port whose signatures mention
/// the implementation is not a port.
public struct CloudRoot: Sendable, Equatable {
    /// The hash of the index the root points at.
    public let hash: String
    /// The generation this pointer was read at. A write is accepted only while
    /// it is still current — that is the whole of the protocol's locking.
    public let generation: Int64

    public init(hash: String, generation: Int64) {
        self.hash = hash
        self.generation = generation
    }
}
