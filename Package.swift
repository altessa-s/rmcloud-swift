// swift-tools-version: 6.3
// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// The protocol of the reMarkable cloud, and nothing else: the client, the tokens,
// the index format, the websocket, the retry policy. Unofficial and
// reverse-engineered — which is exactly why it is worth having behind a wall of
// its own.
//
// One dependency, and it is not a layer: `RedactLog`, for the lines this package
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
    // Pinned to a release tag, exactly: a logger is linked into every package
    // of a host, and two of them built against different versions is how a
    // sink stops receiving lines. The framework build links that same
    // release's `.xcframework` — `Scripts/RedactLog.pin` names it, and
    // `Scripts/fetch-redactlog.sh` checks the two pins agree.
    dependencies: [
        .package(url: "https://github.com/altessa-s/redactlog-swift.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "RMCloud",
            dependencies: [.product(name: "RedactLog", package: "redactlog-swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RMCloudTests",
            dependencies: [
                "RMCloud",
                // Named, and not left to arrive through `RMCloud`: a test that
                // says `import RedactLog` depends on it itself.
                .product(name: "RedactLog", package: "redactlog-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
