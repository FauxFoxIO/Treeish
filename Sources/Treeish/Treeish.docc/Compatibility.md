# Compatibility and repository access

Treeish reads and writes standard Git repositories. It does not introduce a
package-specific repository format.

Inspect ``Repository/capabilities()`` after opening a repository to determine
whether it is writable and which operations are available. This result reflects
the object format, repository format, extensions, and storage features actually
present in that repository. Unknown required extensions or unsupported mutation
formats make the repository read-only or metadata-only rather than risking
corruption.

Treeish reads and writes both SHA-1 and SHA-256 object-format repositories.
Object IDs, loose objects, trees, commits, indexes, packs, pack indexes,
references, reflogs, bundles, and smart-protocol requests use the repository's
declared object format.

Reftable v1 and v2 stacks support symbolic references, peeled values, deletion
records, bounded reflog reads, and append-only reference/reflog transactions.
File and reftable repositories support numbered and date-based reflog revision
selectors, prior-checkout selectors, and branch upstream/push selectors.
Tracking selectors honor configured fetch and push refspec destinations. Stack
publication uses the standard `tables.list.lock` compare-and-swap boundary.

Branch checkout validates that the requested branch already names the requested
commit and moves only symbolic `HEAD`; it never rewrites the branch as a side
effect. ``CheckoutRequest/reflog`` and ``ResetRequest/reflog`` let the host
supply the identity and message used for the corresponding `HEAD` and branch
reflogs.

Signed commits use Git's multiline `gpgsig` header and signed annotated tags
append the canonical armored signature. Treeish constructs and bounds the exact
payload while ``GitObjectSigner`` and ``GitObjectSignatureVerifier`` let the
host own OpenPGP, X.509, or SSH keys and trust policy. System Git can verify
objects produced through this boundary.

``Repository/revert(_:)`` applies the selected commit's inverse through the
same three-way merge used by Git, requires an explicit mainline parent for
merge commits, and creates a single-parent revert commit. Conflicts use the
standard `REVERT_HEAD`, `MERGE_MSG`, and staged index entries, so system Git
and Treeish can inspect, continue, or abort the operation interchangeably.

``Repository/diff(_:)`` returns byte-aware structured file and content changes
between `HEAD`, the index, the worktree, or any commit, tree, or annotated tag.
It applies pathspec and allocation bounds, excludes untracked files from the
worktree target like `git diff`, honors clean conversion, preserves file modes,
and reports gitlinks as canonical subproject-commit content. An index with
unresolved stages is not flattened into a misleading diff;
``Repository/conflicts()`` exposes its exact ancestor, ours, and theirs entries.

``Repository/createStash(_:)`` writes Git's canonical working-tree and index
commits and, when requested, the interoperable third-parent untracked commit.
It updates `refs/stash` with a standard reflog and cleans captured paths through
a recoverable worktree transaction. ``Repository/applyStash(_:)`` accepts the
same topology from Treeish or system Git, performs a three-way tracked
application, restores untracked paths only after collision checks, and
preserves conflict stages. ``Repository/deleteStash(_:)`` provides
compare-and-swap structured deletion for files and reftable repositories.

``Repository/operationState()`` reports canonical merge, cherry-pick, revert,
Treeish rebase, system-Git rebase, and sequencer state together with exact
conflict stages. Starting another commit, checkout, reset, merge, cherry-pick,
revert, rebase, or stash mutation while one of these operations is active
fails with `recoveryRequired`; callers must continue or abort the existing
operation instead of overwriting its recovery metadata.

``Repository/checkIntegrity(_:)`` validates canonical loose and packed objects,
commit/tree/tag connectivity and types, file or reftable references, and
optional reflog roots without mutating the repository. It classifies
unreachable and dangling objects, treats absent promisor objects as warnings,
and does not require gitlink targets to exist in the superproject object
database.

``Repository/listTree(_:options:)`` accepts a tree, commit, or annotated tag,
peels it with bounded cycle detection, and returns immediate or recursive
byte-aware entries. Modes and object kinds match `git ls-tree`; recursive
listing is allocation-bounded and cancellation-aware.

``Repository/configuration()`` and
``Repository/configurationValues(for:)`` return the effective repository
configuration after bounded, root-contained relative includes.
``Repository/setConfiguration(_:)`` and
``Repository/unsetConfiguration(_:)`` mutate only the repository's own config
file through a lockfile compare-and-swap. They preserve included files and
unrelated text, support multivars and continued lines, and refuse keys that
would change the repository format, object format, ref storage, bare state, or
worktree root while the open repository still holds derived capabilities.

Object lookup follows root-contained alternate object databases and classic or
incremental multi-pack indexes. Revision traversal honors `shallow` boundaries
and replacement references. Partial-clone configuration is reported through
``RepositoryCapabilities/promisorRemotes``; ``Repository/readObject(_:services:)``
materializes missing promised objects through smart HTTP or host-provided SSH
and publishes the validated response as a canonical local pack.

``FetchRequest/filter`` and ``CloneRequest/filter`` negotiate Git filter
specifications only when the server advertises the v0 or v2 `filter`
capability. Filtered and demand-fetched packs carry standard `.promisor`
markers. Checkout materializes omitted tree and blob objects before beginning
its recoverable worktree transaction.

``FetchRequest/shallow`` and ``CloneRequest/shallow`` negotiate commit depth,
timestamp cutoffs, excluded revisions, or complete unshallowing over protocol
v0 or v2. Server `shallow` and `unshallow` responses update the standard
shallow-boundary file before fetched references are published.

Receive-pack selects `report-status-v2` ahead of `report-status`, requests
`atomic` only for atomic pushes, frames standard push options, and refuses
reference deletion unless the server advertises `delete-refs`. Deletion-only
pushes omit the packfile; creates and updates always carry a pack, including a
canonical empty pack when the remote already has every required object.

``Repository/pull(_:services:)`` resolves the current branch's configured
upstream, fetches through the native transport, and integrates the fetched
remote-tracking commit by fast-forward-only policy or the native merge engine.
Cancellation follows whichever fetch or merge phase is active.

``FetchRequest/refspecs`` accepts exact or single-wildcard mappings with Git's
leading `+` force and `^` negative forms. ``FetchRequest/prune`` removes only
destinations covered by positive mappings and protects negative selections.
Empty repositories clone without fabricating a commit or reference.
Bare clone maps branch and tag references directly without creating a
worktree. Mirror clone fetches `+refs/*:refs/*`, records `remote.*.mirror`,
preserves the advertised symbolic `HEAD`, and can create detached exact-commit
linked worktrees through ``Repository/createLinkedWorktree(_:)``.

Checkout honors standard `$GIT_DIR/info/sparse-checkout` patterns when
`core.sparseCheckout` is enabled in shared or worktree configuration. Excluded
index entries retain `skip-worktree`, status does not report their intentional
absence as deletion, and staging rejects them unless
``StageRequest/includeSparsePaths`` explicitly opts into Git's `--sparse`
behavior.

Ignore and attribute resolution reads repository-level `info/exclude` and
`info/attributes` through the common Git directory, including from linked
worktrees. Per-directory attributes apply from parent to child and repository
`info/attributes` has highest precedence. Standard `text` and `eol=lf|crlf`
clean/smudge conversion is applied during staging, status, checkout, and
restore; active external filters and working-tree encodings are rejected
instead of silently writing incorrect bytes.

``Repository/submodules()`` combines bounded `.gitmodules` configuration,
stage-zero gitlinks, and nested repository inspection to report uninitialized,
clean, dirty, different-commit, missing-gitlink, and unconfigured states.
Superproject status treats gitlink directories atomically and reports nested
changes without leaking their files as untracked paths. Repository discovery
supports both linked-worktree and standard submodule `.git` indirection.

``Repository/updateSubmodules(_:services:)`` initializes supported HTTPS or
host-provided SSH submodules, resolves relative URLs against the superproject's
branch remote, fetches missing objects, and checks out the exact gitlink commit.
It refuses dirty submodules unless force is explicit, honors `update=none`,
rejects unsupported update commands, bounds recursive updates, and removes a
partially initialized checkout when initialization fails. Clone accepts an
existing empty destination, matching the prerequisite used by submodule
placeholders. ``CheckoutRequest/force`` is the explicit destructive-worktree
opt-in used by forced updates.

Sparse indexes carrying the required `sdir` extension are expanded through
their tree entries before structured operations inspect or rewrite them.
Treeish writes a canonical full index after mutation, which system Git may
compact again. Other unknown lowercase required index extensions, including
split-index `link`, keep index mutation disabled rather than being discarded.
