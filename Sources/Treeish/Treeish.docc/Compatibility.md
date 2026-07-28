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
and replacement references. Partial-clone configuration is recognized and
reported through ``RepositoryCapabilities/promisorRemote``.
