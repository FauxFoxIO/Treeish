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
records, and append-only reference/reflog transactions. Stack publication uses
the standard `tables.list.lock` compare-and-swap boundary.

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

``FetchRequest/depth`` and ``CloneRequest/depth`` negotiate commit depth over
protocol v0 or v2. Server `shallow` and `unshallow` responses update the
standard shallow-boundary file before fetched references are published.

Receive-pack selects `report-status-v2` ahead of `report-status`, requests
`atomic` only for atomic pushes, frames standard push options, and refuses
reference deletion unless the server advertises `delete-refs`. Deletion-only
pushes omit the packfile; creates and updates always carry a pack, including a
canonical empty pack when the remote already has every required object.
