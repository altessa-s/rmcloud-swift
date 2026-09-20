// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// The account as everything above the protocol sees it: registered or not,
/// a code to hand over, a plan to read.
///
/// Deliberately four methods against the provider's seven. The device and
/// user tokens themselves never appear here — they are the one thing that
/// must not travel past `RMCloud`, and a port that offered `userToken()`
/// would be an invitation to carry one into a view model.
public protocol AccountServing: Sendable {
    var isRegistered: Bool { get async throws }
    func registerDevice(oneTimeCode code: String) async throws
    /// Take the device off the account at the server. Leaves the Keychain
    /// alone; `forgetDevice` is the other half, and each is reported on its
    /// own.
    func revokeDevice() async throws
    func forgetDevice() async throws
    func plan() async throws -> CloudPlan?
}

extension TokenProvider: AccountServing {}
