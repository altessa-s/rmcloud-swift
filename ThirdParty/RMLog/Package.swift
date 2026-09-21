// swift-tools-version: 6.3
// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// Process logs, linked in rather than compiled here.
//
// The logging lives in its own repository now (`../../rmlog-swift`), and it left
// for one reason: `RMCloud` has to become a package of its own, and the cloud
// protocol cannot take its diagnostics with it while they belong to this
// application's bottom layer. Moving the logging out from under the domain was
// the alternative to giving the protocol a second, thinner logger of its own —
// and it turned out to be a move rather than a rewrite, because the subsystem
// already depended on nothing but the platform.
//
// What is left here is the wrapper that lets every package above go on saying
// `.package(path: "../ThirdParty/RMLog")` and `import RMLog`. Nothing about how
// a line is written changed: the same facade, the same tags, the same sinks.
// What changed is what the package is allowed to know. It names no categories —
// this application's are in `RMCore/Support/SlateLogCategories.swift`, outside
// the machinery on purpose — and it names neither the subsystem the unified log
// answers to nor the file a sink writes. Those are arguments now, passed from
// each composition root.
//
// **Every host must install its own sinks.** Not calling `Log.bootstrap` used to
// mean the system log under this application's bundle identifier; it now means
// silence, because a logger cannot invent a host's identity. The File Provider
// and share extensions used to rely on that default and bootstrap explicitly
// since — if either goes quiet in `log stream`, that call is the first thing to
// look at.
//
// No dependencies, so nothing here has to be kept in step with anything but the
// version stamp beside it. Why the artefact is committed rather than fetched by
// URL, and why it is dynamic, is written out at length in
// `ThirdParty/RMLines/Package.swift` — every word of it applies here, and the
// duplicate-type hazard it describes is worse for this one: two copies of
// `LogSink` in a process means a sink installed through one of them never
// receives the lines written through the other, silently and at run time.
import PackageDescription

let package = Package(
    name: "RMLog",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RMLog", targets: ["RMLog"]),
    ],
    targets: [
        .binaryTarget(name: "RMLog", path: "RMLog.xcframework"),
    ]
)
