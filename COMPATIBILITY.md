# Treeish compatibility matrix

This matrix describes the current prerelease compatibility envelope. Treeish
uses standard Git repository formats and network protocols; it does not create
a Treeish-specific repository format. “Write” means Treeish can publish the
canonical Git representation. “Reject” means the repository remains readable
where possible, but mutation is disabled before publication.

Applications must inspect `Repository.capabilities()` after opening a
repository. The runtime result takes precedence over this general matrix
because it reflects the repository's actual extensions, index, object format,
reference storage, root policy, and interrupted transactions.

## Repository formats

| Feature | Read | Write | Safely rejected or constrained |
| --- | --- | --- | --- |
| SHA-1 objects and object IDs | Yes | Yes | Invalid lengths and checksums |
| SHA-256 objects and object IDs | Yes | Yes | Mixed-format objects and refs |
| Repository format 0 | Yes | Yes | Nonzero required extensions |
| Repository format 1 | Yes | Yes, when every required extension is understood | Unknown required extensions disable mutation |
| Loose objects | Yes | Yes | Oversized, truncated, or hash-mismatched objects |
| Pack v2/v3, OFS/REF deltas, thin packs | Yes | Yes; Treeish emits canonical packs | Unsupported versions, excessive delta depth, aggregate-size overflow |
| Pack index v2 | Yes | Yes | Unsupported versions and inconsistent fanout/offset/checksum data |
| Alternate object databases | Yes, when root-contained or explicitly allowed | Objects are written to the primary store | Escaping alternates |
| Multi-pack-index v1/v2 and incremental chains | Yes | No maintenance writer | Malformed or unsupported chains |
| Index v2/v3/v4 | Yes | Yes | Unknown required lowercase extensions disable index mutation |
| Sparse index (`sdir`) | Yes, expanded for structured operations | Yes, as a canonical full index | Malformed sparse directories |
| Split index (`link`) | Metadata/open only where safe | No | Index mutation is disabled |
| Files refs, packed refs, symbolic refs, reflogs | Yes | Yes | Invalid names, symbolic loops, compare-and-swap mismatch |
| Reftable v1/v2 refs and reflogs | Yes | Yes, append-only transactions | Unsupported versions or invalid stacks |
| Normal repositories | Yes | Yes | Worktree paths outside the granted root |
| Bare repositories | Yes | Repository metadata, objects, and refs | Worktree-only operations |
| Linked worktrees | Yes | Yes | Collisions, invalid admin links, or roots outside policy |
| Shallow repositories | Yes | Fetch/unshallow and standard boundary updates | Traversal beyond an absent shallow parent |
| Partial/promisor repositories | Yes | Fetch and on-demand object materialization | Missing objects without a configured, capable promisor |

## Structured operation surface

| Portable command concept | Treeish API | Current support |
| --- | --- | --- |
| `status` | `Repository.status` | Staged, worktree, untracked, ignored, gitlink, sparse, and unmerged state |
| `diff` | `Repository.diff`, `diffBlobs` | HEAD/index/worktree/tree-ish, modes, binary/text, pathspec bounds |
| `add` | `Repository.stage` | Add, modify, delete, sparse opt-in, ignore and clean conversion |
| `restore` | `Repository.restore` | Index and worktree restoration from a commit |
| `commit` | `Repository.commit` | CAS reference publication and optional host-backed signing |
| `log` | `Repository.log` | Bounded commit traversal |
| `show` | `readObject`, `log`, `listTree`, `diff` | Structured object/commit/tree/diff composition; no porcelain text renderer |
| `branch` | ref listing/create/delete and upstream resolution | Local branches and tracking configuration |
| `switch`, `checkout` | `Repository.checkout` | Branch or detached exact-commit checkout |
| `merge` | `merge`, `continueMerge`, `abortMerge` | Fast-forward, three-way, conflict stages, continuation, abort |
| `rebase` | `rebase`, `continueRebase`, `abortRebase` | Caller-supplied ordered commit replay |
| `cherry-pick` | `cherryPick`, continuation, abort | Single-commit apply with conflict state |
| `revert` | `revert`, continuation, abort | Root, normal, and mainline-selected merge commits |
| `reset` | `Repository.reset` | Soft, mixed, and hard |
| `stash` | `createStash`, `stashes`, `applyStash` | Canonical tracked-change stash create/list/apply; untracked capture and drop/pop are not yet supported |
| `fetch` | `Repository.fetch` | HTTPS/SSH, refspecs, prune, shallow, partial, quarantine |
| `pull` | `fetch` followed by upstream resolution and `merge` | Supported as explicit host orchestration; no single convenience operation yet |
| `push` | `Repository.push` | CAS updates, creates, deletes, atomic batches, push options |
| `tag` | `createTag`, ref APIs | Lightweight and signed/unsigned annotated tags |
| `worktree` | linked-worktree create/list/lock/unlock/remove | Exact-commit linked worktrees |
| `submodule` | `submodules`, `updateSubmodules` | Status, initialization, fetch, exact gitlink checkout, bounded recursion |
| `rev-parse` | `resolveRevision`, `resolveRevisionRange` | Names, ancestry, peel/type selectors, reflog, upstream/push selectors |
| `reflog` | `reflog`, `headReflog` | Files-ref and reftable logs |
| `cat-file` | `readObject` | Typed canonical object payload |
| `ls-tree` | `listTree` | Immediate/recursive byte-aware listings |
| `fsck` | `checkIntegrity` | Checksums, connectivity, refs/reflogs, promised gaps, unreachable objects |

## Worktree and content behavior

| Feature | Read | Write | Constraint |
| --- | --- | --- | --- |
| Regular/executable files and symlinks | Yes | Yes | Filesystem collisions fail before publication |
| Byte-aware repository paths | Yes | Yes | A host filesystem that cannot represent a path disables that worktree mutation |
| Ignore and `info/exclude` rules | Yes | Stage/status behavior | Bounded pattern parsing |
| `text` and `eol=lf/crlf` attributes | Yes | Yes | External filters, working-tree encodings, and unsupported conversions are rejected |
| Sparse checkout | Yes | Yes | Excluded paths require explicit sparse staging opt-in |
| Gitlinks and `.gitmodules` | Yes | Yes for supported checkout updates | Custom submodule update commands are rejected |
| Bundle-backed workspace transfer | Yes | Yes | Imported objects are validated before refs publish |
| Interrupted worktree transaction | Recovery on open | Resume only after reconciliation | Corrupt or unknown journals disable mutation |
| Merge/cherry/revert/rebase state | Yes, including exact conflict stages | Continue or abort through the matching API | Unrelated mutations are blocked while state is active |

## Transport and authentication

| Feature | Support |
| --- | --- |
| Smart HTTP protocol v2 | Native |
| Smart HTTP protocol v0/v1 advertisement fallback | Native |
| Git-over-SSH | Native Git framing over a host-provided authenticated, host-verified session |
| GitHub App or personal access token | Ephemeral host-provided credential; never persisted by Treeish |
| Basic and Bearer credentials | Ephemeral host-provided credential |
| Credential helpers and global Git config | Not read |
| Production Git subprocess fallback | None |

## Explicit safe-rejection boundary

Treeish does not mutate repositories when it encounters an unknown required
repository extension, unsupported object or ref storage, an unreadable or
non-rewritable required index extension, a corrupt recovery journal, paths
outside the granted filesystem root, unsupported content conversion, unresolved
operation state belonging to another mutation, or a failed compare-and-swap
precondition.

System Git appears only in development interoperability tests as an oracle. A
production source search under `Sources/` contains no `Process` or
`/usr/bin/git` invocation.
