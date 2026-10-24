// swift-tools-version: 6.3
// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// The protocol of the reMarkable cloud, and nothing else: the client, the tokens,
// the index format, the websocket, the retry policy. Unofficial and
// reverse-engineered — which is exactly why it is worth having behind a wall of
// its own.
//
// Dependencies provide logging, hashing and portable networking. Everything
// it needs from a host arrives as a port — three secrets
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
        .package(url: "https://github.com/altessa-s/redactlog-swift.git", exact: "0.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "RMCloud",
            dependencies: [
                .product(name: "RedactLog", package: "redactlog-swift"),
                // Only where CryptoKit is absent: on Apple the system module is
                // used, and an unconditional product would make every consumer
                // resolve and link swift-crypto for nothing.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])),
                .product(name: "NIO", package: "swift-nio", condition: .when(platforms: [.linux, .windows])),
                .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.linux, .windows])),
                .product(name: "NIOWebSocket", package: "swift-nio", condition: .when(platforms: [.linux, .windows])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RMCloudTests",
            dependencies: [
                "RMCloud",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),

                // Named, and not left to arrive through `RMCloud`: a test that
                // says `import RedactLog` depends on it itself.
                .product(name: "RedactLog", package: "redactlog-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
