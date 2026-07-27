# Compatibility and repository access

Treeish reads and writes standard Git repositories. It does not introduce a
package-specific repository format.

The checked-in `compatibility.json` file describes Treeish's general read and
write support in a machine-readable form. It covers object and repository
formats, storage, transport, and higher-level operations.

An individual repository can be more restricted than that general matrix.
Inspect ``Repository/capabilities()`` after opening a repository to determine
whether it is writable and which operations are available. Unknown required
extensions or unsupported mutation formats make the repository read-only or
metadata-only rather than risking corruption.
