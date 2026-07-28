# Treeish

### Put a real Git engine inside your Swift app.

Treeish lets an iPhone or Mac app clone repositories, inspect history, stage
files, create commits, manage branches, merge, rebase, and push—without
installing Git, launching a subprocess, or shipping a C library.

It reads and writes the same repositories as command-line Git. Objects, packs,
indexes, references, reflogs, worktrees, and network exchanges are implemented
as native Swift code with structured concurrency.

Treeish is built for products where Git is a feature, not an external tool:

- coding agents and mobile IDEs;
- visual Git clients and repository browsers;
- document or project apps that use Git as a storage format;
- sandboxed automation that cannot launch `/usr/bin/git`; and
- apps that need typed progress, cancellation, and controlled filesystem access.

> [!IMPORTANT]
> Treeish is prerelease software. Its Swift API can make hard cutovers before
> 1.0. Repositories created by Treeish remain standard Git repositories.

## Why Treeish?

Most Swift Git integrations either invoke the Git executable or bridge a C
library. Both are reasonable on a developer Mac, but awkward inside a sandboxed,
portable application.

Treeish takes a different approach:

| | Treeish |
| --- | --- |
| Runtime | Native Swift 6 with strict concurrency |
| Repository format | Standard Git, interoperable with command-line Git |
| Process model | No subprocesses in production |
| Dependencies | No third-party packages and no C-family source targets |
| Platforms | iOS 17.4+ and macOS 14+ |
| Operations | Typed results, progress streams, and cancellation |
| Filesystem access | Explicitly scoped through `TreeishRoot` |
| Authentication | Credentials and SSH trust remain owned by your app |

Treeish does not hide Git behind a simplified key-value API. It gives an
application structured access to Git concepts while preserving the formats and
behavior that make a repository portable.

## Add Treeish to your package

Treeish has not published a 1.0 release yet, so pin a revision for reproducible
builds:

```swift
dependencies: [
    .package(
        url: "https://github.com/FauxFoxIO/Treeish.git",
        revision: "<treeish-commit>"
    ),
]
```

Add its single public product to the target that owns repository operations:

```swift
.target(
    name: "SourceControl",
    dependencies: [
        .product(name: "Treeish", package: "Treeish"),
    ]
)
```

Treeish requires Swift 6.2 or newer.

## Clone and inspect a repository

A `TreeishRoot` grants access to a directory. Clone destinations and discovered
repositories must remain inside that root.

```swift
import Foundation
import Treeish

let downloads = try await TreeishRoot.localDirectory(at: downloadsURL)
let request = try CloneRequest(
    remote: RemoteURL("https://github.com/FauxFoxIO/Treeish.git"),
    destination: GitPath("Treeish")
)

let repository = try await Treeish.clone(request, in: downloads)
let snapshot = try await repository.snapshot()
let status = try await repository.status().value()

print(snapshot.headReference?.description ?? "detached HEAD")
print(snapshot.headObjectID?.description ?? "unborn branch")
print(status.isClean ? "clean" : "\(status.entries.count) changed paths")
```

Cloning produces a normal working repository. Command-line Git can open it, and
Treeish can reopen a repository created by command-line Git.

To discover an existing repository from any directory beneath its worktree:

```swift
let workspace = try await TreeishRoot.localDirectory(at: workspaceURL)
let location = try await Treeish.discover(in: workspace)
let repository = try await Treeish.open(location, roots: [workspace])
```

Discovery understands normal repositories, bare repositories, `.git` files,
and linked worktrees.

## Make a commit

Treeish keeps each publication step explicit. Your app writes the file, stages
the path, writes the index tree, and creates a commit with compare-and-swap
protection for `HEAD`.

```swift
let readmeURL = checkoutURL.appendingPathComponent("README.md")
try Data("# My project\n".utf8).write(to: readmeURL)

_ = try await repository.stage(
    StageRequest(pathspecs: [
        try GitPathspec("README.md"),
    ])
).value()

let tree = try await repository.writeIndexTree().value()
let before = try await repository.snapshot()
let identity = Signature(
    name: "A Developer",
    email: "developer@example.com",
    secondsSinceEpoch: Int64(Date().timeIntervalSince1970),
    timeZoneOffsetMinutes: 0
)

let commit = try await repository.commit(
    CommitRequest(
        tree: tree,
        parents: before.headObjectID.map { [$0] } ?? [],
        expectedHead: before.headObjectID,
        author: identity,
        committer: identity,
        message: Array("Add README\n".utf8)
    )
).value()

print("Created \(commit.objectID)")
```

`expectedHead` prevents an operation from silently overwriting a reference that
changed after the app took its snapshot.

## Work with long-running operations

Repository work that may touch many files or objects returns a
`GitOperation<Result>`. The operation starts immediately. Await its typed result,
observe progress, or cancel it from another task.

```swift
let operation = await repository.fetch(
    try FetchRequest(
        remote: RemoteURL("https://github.com/FauxFoxIO/Treeish.git")
    )
)

let progress = Task {
    for await event in operation.events {
        print(event.phase, event.completedUnits ?? 0, event.totalUnits ?? 0)
    }
}

let result = try await operation.value()
await progress.value

print("Received \(result.receivedObjects) objects")
```

`Repository` is an actor, while requests, results, snapshots, and progress
events are `Sendable`. An application can keep repository ownership out of the
main actor without inventing its own locking model.

## Authenticate with GitHub

Treeish asks for an HTTPS credential at the point of use. It does not read a
credential helper, persist the token, or put secrets in a remote URL.

Store the token in your app’s secure storage and only return it for the host you
intend to trust:

```swift
struct GitHubCredentials: GitCredentialProvider {
    let token: String

    func credential(
        for challenge: GitAuthenticationChallenge
    ) async throws -> GitCredentialDisposition {
        guard challenge.scheme == "https",
              challenge.host == "github.com"
        else {
            return .reject
        }

        return .use(.githubToken(token))
    }
}

let services = RepositoryServices(
    credentials: GitHubCredentials(token: tokenFromKeychain)
)

let repository = try await Treeish.clone(
    try CloneRequest(
        remote: RemoteURL("https://github.com/owner/private-repository.git"),
        destination: GitPath("private-repository")
    ),
    in: downloads,
    services: services
)
```

`GitCredential.githubToken` sends the token as the password in HTTP Basic
authentication, which is the convention GitHub uses for Git over HTTPS.
Credential descriptions are always redacted.

The same `RepositoryServices` value can be passed to `fetch` and `push`.

## Connect over SSH

Treeish understands both common SSH remote forms:

```swift
let scpStyle = try RemoteURL("git@github.com:owner/repository.git")
let urlStyle = try RemoteURL(
    "ssh://git@github.example.com:2222/owner/repository.git"
)
```

SSH policy belongs to the embedding application. Supply an `SSHGitTransport`
that opens an authenticated, host-verified session:

```swift
let services = RepositoryServices(
    sshTransport: applicationSSHTransport
)

let repository = try await Treeish.clone(
    try CloneRequest(
        remote: RemoteURL("git@github.com:owner/repository.git"),
        destination: GitPath("repository")
    ),
    in: downloads,
    services: services
)
```

Treeish drives `git-upload-pack` and `git-receive-pack` over the returned
stateful session. Your transport owns encryption, key storage, user
authentication, host-key verification, and securely starting the requested Git
service. Treeish intentionally does not make trust-on-first-use or keychain
decisions for the host app.

## What works today

### Repository storage

- SHA-1 and SHA-256 loose objects, packfiles, pack indexes, and indexes;
- OFS and REF deltas, thin-pack resolution, pack indexes, and zlib streams;
- repository formats 0 and 1 when all required extensions are understood,
  normal repositories, and bare repositories;
- loose, symbolic, and packed references with reflogs, plus bounded reftable
  v1/v2 stacks, atomic updates, tombstones, and reflogs; and
- index versions 2–4, extended entry flags, optional index extensions,
  executable files, symbolic links, ignore rules, and attributes.

### Everyday Git

- initialize, discover, open, clone, fetch, and push;
- staged and unstaged status, stage, commit, checkout, restore, and reset;
- branches, lightweight and annotated tags, and linked worktrees;
- revision expressions, ancestry, ranges, logs, and merge bases;
- merge, cherry-pick, rebase, continuation, conflict state, and abort;
- unified patches, bundles, blob diffs, and binary-safe workspace snapshots.

### Networking

- Git smart HTTPS with protocol v2 and protocol v0 fallback;
- Git-over-SSH through an application-provided stateful session;
- GitHub token authentication and general Basic or Bearer credentials; and
- validated pack publication before remote-tracking references move.

Treeish reads and mutates reftable repositories, including symbolic references,
peeled tags, deletion records, and append-only reference/reflog transactions.
It does not mutate repository-format-1 repositories containing unsupported
required extensions. Inspect `repository.capabilities()` after opening an
unfamiliar repository. Unknown required extensions make the repository
read-only or metadata-only instead of risking corruption.

## Safety model

Repository contents are untrusted input. Treeish applies explicit resource
limits while parsing configs, objects, packs, indexes, references, and network
messages. Filesystem access is rooted, paths are byte-aware, received objects
are quarantined until validation succeeds, and multi-file worktree changes use
recoverable transactions.

Remote effects are treated differently from local writes. A failed push can
have an indeterminate outcome because the server may have accepted a reference
before the connection disappeared. Treeish reports that state for
reconciliation instead of pretending the operation definitely failed.

System Git is used as an interoperability oracle in the test suite. It is never
used as a production backend.

## Design boundaries

Treeish ships one public library product. Internal targets isolate object,
pack, index, graph, diff, protocol, HTTP, and filesystem concerns without
forcing those implementation modules into an app’s dependency graph.

The package contains Swift source only. Compression uses Apple’s system
`Compression` framework, and production code never launches `git`.

## Contributing

Changes should preserve standard Git interoperability and include Swift Testing
coverage for observable behavior. Start with:

```sh
swift test
swift build --configuration release
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for repository rules and the full
platform-validation expectations.

## License

Treeish is available under the [MIT License](LICENSE).
