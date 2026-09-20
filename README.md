# RMCloud

The reMarkable cloud's sync protocol, and nothing else: the client, the token exchange, the index format, the notification socket,
the retry policy. Unofficial and reverse-engineered — which is exactly why it is worth having behind a wall of its own.

A standalone package. It was carved out of a macOS application once it stopped needing anything of it: it asks for the three
secrets it holds through a port, reports progress as a closure, and answers with types of its own.

## Why it exists

A protocol nobody documents is learned by watching it, and what you learn ends up written down as code. That code should not also
know what a Finder item is, where a log file goes, or what an application calls its Keychain accounts — because the moment it
does, the knowledge is stuck inside one product.

Everything here was measured against a live account. The schema versions, the hash addressing, the generation dance on a root
write, the `sourceDeviceDesc` a notification carries, the claims a user token puts in its payload: none of it is invented, and
none of it is specified anywhere either. That is the asset, and it is the reason for the wall.

## What it depends on

`RMLog`, for the lines it writes. Nothing else.

That was not free, and the seams are worth knowing about.

- **The three secrets arrive through a port.** `CloudSecretStoring` asks for `deviceToken`, `deviceID` and `userToken` by name.
  A host does not write an adapter: whatever it already keeps secrets in conforms to the protocol as well. The raw values are a
  contract with what is already on people's machines — a rename reads nothing, finds no device token, and looks to the user like
  an account that disconnected overnight.
- **Progress is a closure.** `TransferProgress` is `(completed, total) -> Void`, a typealias for a function type rather than a
  nominal one, so a host's own name for the same shape *is* this one and nothing converts at the seam.
- **What it answers with is its own.** `CloudRoot`, `DocumentIndex`, `IndexEntry`, `CloudError`, `CloudPlan`. A host that has a
  domain of its own converts at the door — two fields for the plan, one `switch` for the error — which is cheaper than either
  side importing the other to say the same two strings.
- **Diagnostics go to whatever the host installed.** `Log.cloud` on `RMLog`; the category is declared here, because a package
  that logs names its own channel.

## Design

**The wire can be read.** `RMCLOUD_WIRE_LOG=headers` writes every request and response with its headers; `bodies` adds the ones
that are text, JSON or XML. Credentials are masked and query strings are dropped — a storage URL's signature is a credential too.
It is the single most useful thing in here when the service changes under you.

**The hosts can be pointed elsewhere.** `RMCLOUD_HOST`, `RMCLOUD_AUTH_HOST` and `RMCLOUD_SYNC_HOST` send the client to a fake
server — HTTPS anywhere, plain HTTP on the loopback only — through `CloudEndpoints.fromEnvironment()`. For debugging and for
`rmctl`; a shipped build never reads them, because whoever names the host receives the tokens.

**Tokens never leave this package and the store.** The sequence is an 8-character code, then a device token, then a short-lived
user token read for its own expiry. There is no `userToken()` on the port a host gets: `AccountServing` answers whether the
device is registered, takes a code, revokes, forgets, and reports the plan. Disconnecting revokes at the service *first* and
forgets locally second — a refusal never leaves the token on the machine.

**An index is not a document.** `DocumentIndex` and `IndexEntry` are the wire's own shapes, down to the schema version in the
first line and the `:`-separated columns after it. A hash that is not SHA-256 is reported rather than guessed at, and contents
that do not match the hash they were fetched by are refused before anybody sees them.

**Reading is narrower than writing.** `BlobFetching` is two ways of getting bytes and no way to write. A drawing path handed that
protocol cannot call `putRoot` by accident, because it cannot name it.

**A download has a ceiling.** The size a record declares is the ceiling the transfer is held to, and an undeclared size falls
back to a general one. A response running past its declared length is refused rather than written out — an original goes to disk,
and nothing above the transport can refuse bytes that have already landed there.

**Errors are frozen.** Every public enum is `@frozen`. The framework ships in lockstep with whatever links it, so there is no ABI
to protect, and an exhaustive `switch` in a consumer is the point: the one place that turns a `CloudError` into something a person
reads must break its build when a case is added, not fall into an `@unknown default`.

## Using this package

**As a source dependency:**

```swift
dependencies: [
    .package(path: "../rmcloud-swift"),
    // or .package(url: "…/rmcloud-swift.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourTarget",
        // The package is identified by its directory — `rmcloud-swift` —
        // not by the library product it vends, which is `RMCloud`.
        dependencies: [.product(name: "RMCloud", package: "rmcloud-swift")]
    ),
]
```

`RMLog` comes with it: the framework is committed under `ThirdParty/` and declared as a path dependency, so a consumer names
nothing else.

**As a binary.** A release attaches `RMCloud.xcframework.zip`, a dynamic framework of both macOS slices, and the consumer names
it as a binary target:

```swift
targets: [
    .binaryTarget(name: "RMCloud", path: "RMCloud.xcframework"),
]
```

It **links** `RMLog` and does not embed it: two copies of `LogSink` in one process means a sink the host installed never receives
the lines this one writes, silently and at run time. So a host carries one copy of each framework and links the rest.

A binary module carries no testability, so a consumer's tests see the public API only. A test that needs the inside of the
protocol belongs in this repository.

Reading a library, once the device is registered:

```swift
let secrets: any CloudSecretStoring = …                   // the host's own store, conforming
let tokens = TokenProvider(secrets: secrets)
let client = CloudClient(resolver: EndpointResolver(tokens: tokens), tokens: tokens)

let (root, index) = try await client.rootIndex()
for entry in index.entries where entry.isDocument {
    let document = try await client.index(hash: entry.hash, name: entry.indexName)
    if let metadata = document.entry(withExtension: "metadata") {
        let state = try DocumentState.decode(
            try await client.blob(hash: metadata.hash, name: metadata.documentID)
        )
        print(state.visibleName)
    }
}
```

## Building the framework

```sh
Scripts/build-xcframework.sh                                # -> build/RMCloud.xcframework
Scripts/build-xcframework.sh ../some-app/ThirdParty/RMCloud # and install it there
Scripts/fetch-framework.sh RMLog                            # refresh the dependency
```

`Package.swift` is the real project; `project.yml` beside it declares the same sources once more as a framework target, because
SwiftPM cannot produce a `.framework` — archiving its library product leaves a bare `.o`. The script generates that project with
XcodeGen, archives it for macOS (arm64 and x86_64), checks that what came out is a dynamic framework of both slices, and wraps it.
The generated project is not committed.

## Releasing

Push a tag. `1.2.0` and `v1.2.0` both work, and a hyphen makes it a pre-release (`1.2.0-beta.2`).

```sh
git tag 1.2.0 && git push origin 1.2.0
```

The tag runs the suites first — a release is the one artefact nobody re-reads, it is linked — then builds the framework, zips it
with `ditto` (an `.xcframework` is a bundle of symlinks, and a plain `zip` unpacks into something Xcode declines), and publishes
it with the lines a consumer pastes:

```swift
.binaryTarget(
    name: "RMCloud",
    url: "…/releases/download/1.2.0/RMCloud.xcframework.zip",
    checksum: "…"
)
```

The checksum is computed in the same step from the very bytes that are uploaded, which is the reason this is a workflow and
nothing anybody does by hand: a remote binary target resolves by `url` **and** `checksum`, and one worked out on somebody's laptop
is a checksum of what was on that laptop.

The tag is also the version the framework declares. `project.yml` carries 1.0.0 so that a local build needs no ceremony, and the
release overrides it — a framework in a 1.2.0 release that calls itself 1.0.0 is a discrepancy nothing would report. To reproduce
a release build locally:

```sh
RMCLOUD_VERSION=1.2.0 Scripts/build-xcframework.sh
```

## Tests

`swift test` — 175 of them, and they are the specification: what the client does when the wire answers well, what it does when it
answers badly, what it writes byte for byte, and a real local server driven end to end. The doubles are here too, a scripted
transport and a queue of socket frames, because a package that cannot be tested without the application it came out of has not
actually left.
