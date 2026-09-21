// swift-tools-version: 6.3
// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// The protocol of the reMarkable cloud, and nothing else: the client, the tokens,
// the index format, the websocket, the retry policy. Unofficial and
// reverse-engineered — which is exactly why it is worth having behind a wall of
// its own.
//
// One dependency, and it is not a layer: `RMLog`, for the lines this package
// writes. Everything else it needs from a host arrives as a port — three secrets
// through `CloudSecretStoring`, progress as a closure — and everything it answers
// with is its own: `CloudRoot`, `DocumentIndex`, `CloudError`, `CloudPlan`. It
// knows of no application, no file system and no window.
import PackageDescription

let package = Package(
    name: "RMCloud",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RMCloud", targets: ["RMCloud"]),
    ],
    // The released framework, not the sources. `RMLog` is a repository of its own
    // and private, and a private release asset cannot be a SwiftPM binary target
    // by URL at all — the wrapper under `ThirdParty/` says why, at length. So it
    // is a directory here holding its `.xcframework`, its version stamp and a
    // one-target wrapper, fetched by `Scripts/fetch-framework.sh` and committed. A
    // clone builds with no network and no credentials, and the framework build
    // agrees by construction: `project.yml` links the very same artefact.
    dependencies: [
        .package(path: "ThirdParty/RMLog"),
    ],
    targets: [
        .target(
            name: "RMCloud",
            dependencies: [.product(name: "RMLog", package: "RMLog")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RMCloudTests",
            dependencies: [
                "RMCloud",
                // Named, and not left to arrive through `RMCloud`: `RMLog` is a
                // binary framework, and a binary module is linked rather than
                // re-exported — a test that says `import RMLog` needs it on its
                // own link line.
                .product(name: "RMLog", package: "RMLog"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
