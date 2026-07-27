# Treeish

Native Git for Swift.

Treeish is a Swift package for reading, creating, and modifying real Git
repositories on iOS and macOS. It implements Git’s repository formats and smart
HTTP protocol directly—without bundling libgit2 and without launching the `git`
executable in production.

Treeish is useful when an app needs structured, cancellable Git operations in a
sandboxed or portable Swift runtime.

> [!IMPORTANT]
> Treeish is prerelease software. Its Swift API may change without compatibility
> shims before the first stable release. Repositories written by Treeish remain
> standard Git repositories.

## Requirements

- Swift 6.2 or newer
- iOS 17.4 or newer
- macOS 14 or newer
- zlib

All public values conform to `Sendable`, and the package is compiled with Swift
6 strict concurrency.

## Installation

Add Treeish to your package dependencies:

```swift
dependencies: [
    .package(
        url: "https://github.com/FauxFoxIO/Treeish.git",
        branch: "main"
    ),
]
```

Then add the `Treeish` product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Treeish", package: "Treeish"),
    ]
)
```

Import the package with:

```swift
import Treeish
```

Until Treeish publishes versioned releases, pin a commit revision when you need
reproducible builds.

## Quick start

Open an existing repository by creating a filesystem root, discovering its Git
directory, and opening the discovered location:

```swift
import Foundation
import Treeish

let root = try await TreeishRoot.localDirectory(at: workspaceURL)
let location = try await Treeish.discover(in: root)
let repository = try await Treeish.open(location, roots: [root])

let snapshot = try await repository.snapshot()
print(snapshot.headReference?.description ?? "detached HEAD")
print(snapshot.headObjectID?.description ?? "unborn branch")
```

`Treeish.discover` supports normal repositories, bare repositories, `.git`
gitfiles, and linked worktrees.

## Create and inspect a repository

```swift
let root = try await TreeishRoot.localDirectory(at: projectDirectory)
let repository = try await Treeish.initialize(
    in: root,
    options: RepositoryInitialization(initialBranch: "main")
)

let status = try await repository.status().value()
print(status.isClean)
```

Repository methods that may perform substantial work return a
`GitOperation<Result>`. Await `value()` for the result, observe `events` for
typed progress, or call `cancel()`:

```swift
let operation = await repository.stage(
    StageRequest(pathspecs: [try GitPathspec("Sources/**")])
)

let progress = Task {
    for await event in operation.events {
        print(event.phase, event.completedUnits ?? 0)
    }
}

let update = try await operation.value()
progress.cancel()

print("Updated:", update.addedOrUpdated.map(\.displayString))
```

## Clone over HTTPS

Treeish implements Git smart HTTP directly. Remote URLs are HTTPS-only and
credentials are requested through a host-provided `GitCredentialProvider`;
credentials are not stored by Treeish.

```swift
let parent = try await TreeishRoot.localDirectory(at: downloadsDirectory)
let remote = try RemoteURL(
    URL(string: "https://github.com/FauxFoxIO/Treeish.git")!
)
let request = try CloneRequest(
    remote: remote,
    destination: GitPath("Treeish")
)

let repository = try await Treeish.clone(request, in: parent)
```

For authenticated remotes, provide scoped services:

```swift
struct Credentials: GitCredentialProvider {
    let token: String

    func credential(
        for challenge: GitAuthenticationChallenge
    ) async throws -> GitCredentialDisposition {
        guard challenge.host == "github.com" else {
            return .reject
        }
        return .use(.bearer(token))
    }
}

let services = RepositoryServices(
    credentials: Credentials(token: token)
)
```

Never embed credentials in a `RemoteURL`.

## Supported Git features

Treeish currently supports:

- SHA-1 loose objects and packfiles, including OFS and REF deltas
- repository format 0, normal and bare repositories
- loose, symbolic, and packed references with reflogs
- index v2, staging, status, commits, checkout, restore, and reset
- revision resolution, ancestry, reflog selectors, and revision ranges
- branches, annotated and lightweight tags, and linked worktrees
- merge, cherry-pick, typed rebase, unified patches, and bundles
- smart HTTPS using Git protocol v2 with protocol v0 server fallback
- binary-safe workspace capture and restore

SSH transport, SHA-256 object repositories, and mutation of repository format 1
are not currently supported.

### What is `compatibility.json`?

[`compatibility.json`](compatibility.json) is the canonical, machine-readable
capability matrix for the current Treeish revision. It records read and write
support separately for object formats, repository formats, storage formats,
transports, and higher-level Git operations.

It is intended for:

- CI checks that prevent unsupported capabilities from being advertised;
- downstream packages that need to gate features without parsing this README;
- release tooling that compares compatibility between revisions; and
- maintainers updating implementation, tests, and documentation together.

It is not consumed by Swift Package Manager and it does not alter a repository’s
on-disk format. Runtime decisions for a particular repository come from
`Repository.capabilities()`, because extensions or formats found in that
repository may make it read-only even when Treeish generally supports mutation.

```swift
let capabilities = await repository.capabilities()

switch capabilities.access {
case .readWrite:
    // Mutation is available for this repository.
case .readOnly(let reason):
    print("Read-only:", reason)
case .metadataOnly(let reason):
    print("Metadata only:", reason)
}
```

Unknown required repository extensions disable mutation rather than risking
repository corruption.

## Design and safety

Treeish treats repository-controlled data as untrusted. Parsing and mutation are
bounded by configurable `TreeishResourceLimits`, filesystem access is scoped to
a `TreeishRoot`, and multi-file worktree changes use recoverable transactions.
Received objects are validated before references are published.

The package exposes one public library product, `Treeish`. Its focused internal
modules cover objects, packs, indexes, graphs, diffs, protocols, HTTP, and
root-scoped filesystem access.

System Git is used as an interoperability oracle in tests, never as a production
backend.

## Contributing

Contributions should preserve canonical Git interoperability and include Swift
Testing coverage. See [CONTRIBUTING.md](CONTRIBUTING.md) for the project rules.

Run the test suite with:

```sh
swift test
```

## License

Treeish is available under the [MIT License](LICENSE).
