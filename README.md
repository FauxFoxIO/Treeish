# Treeish

Treeish is a native Swift implementation of Git for iOS and macOS. It reads and
writes canonical Git repositories without libgit2 and without launching Git in
production.

The package is prerelease. Its public API and capability matrix may change
without compatibility adapters until the first stable release.

## Supported profile

- repository format 0
- SHA-1 loose and packed objects, including OFS/REF deltas
- normal and bare repositories
- `.git` gitfiles and linked-worktree discovery
- loose, symbolic, and packed refs with lockfile compare-and-swap and reflogs
- index v2 staging, status, commits, checkout, restore, and reset
- full/abbreviated revisions, parents/ancestors, tree lookup, reflog selectors,
  two-dot and three-dot revision ranges
- branches, annotated/lightweight tags, linked worktrees, bundles, merge,
  cherry-pick, and typed rebase
- smart HTTPS Git protocol v2 with protocol v0 server fallback, injected
  credentials, and injected deterministic transport
- safe repository initialization and descriptor-relative atomic filesystem access
- crash-recoverable index/worktree/ref publication and binary-safe workspace
  capture/restore

Unsupported required repository extensions disable mutation. See
`compatibility.json` for the machine-readable profile.
