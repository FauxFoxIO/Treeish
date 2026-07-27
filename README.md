# Treeish

Native Git for Swift.

Treeish is a Swift package for reading, creating, and modifying real Git
repositories on iOS and macOS. It implements Git’s repository formats and
network protocol directly—without bundling libgit2 and without launching the
`git` executable in production.

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

All public values conform to `Sendable`, and the package is compiled with Swift
6 strict concurrency. Git’s zlib streams are implemented in Swift over Apple’s
system `Compression` framework; Treeish contains no C-family source targets.

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

## Remote repositories

Treeish supports Git smart HTTPS and Git-over-SSH for clone, fetch, and push.
Credentials and SSH trust decisions stay with the embedding application.

Clone a public HTTPS repository:

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

For a private GitHub HTTPS repository, return a GitHub token only for the
expected host. GitHub Git authentication uses HTTP Basic authentication with the
token as the password:

```swift
struct Credentials: GitCredentialProvider {
    let token: String

    func credential(
        for challenge: GitAuthenticationChallenge
    ) async throws -> GitCredentialDisposition {
        guard challenge.host == "github.com" else {
            return .reject
        }
        return .use(.githubToken(token))
    }
}

let services = RepositoryServices(
    credentials: Credentials(token: token)
)

let repository = try await Treeish.clone(
    request,
    in: parent,
    services: services
)
```

Never embed credentials in a `RemoteURL`.

For SSH, use either an `ssh://` URL or the familiar SCP-style syntax and provide
an `SSHGitTransport`:

```swift
let remote = try RemoteURL(
    "git@github.com:FauxFoxIO/Treeish.git"
)
let request = try CloneRequest(
    remote: remote,
    destination: GitPath("Treeish")
)
let services = RepositoryServices(sshTransport: applicationSSHTransport)

let repository = try await Treeish.clone(
    request,
    in: parent,
    services: services
)
```

Treeish owns the Git upload-pack and receive-pack protocol carried by the SSH
session. The injected transport owns the encrypted connection, user/key
authentication, and host-key verification. This keeps security policy and key
storage in the host application while preserving a native, subprocess-free Git
implementation.

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
- Git-over-SSH through host-provided stateful SSH sessions
- binary-safe workspace capture and restore

SHA-256 object repositories and mutation of repository format 1 are not
currently supported.

Inspect a repository’s runtime capabilities before presenting mutating
operations. Extensions or formats found in that repository may make it
read-only even when Treeish generally supports mutation:

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
Scripts/validate-package.sh
swift test
```

## License

Treeish is available under the [MIT License](LICENSE).
