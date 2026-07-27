# Compatibility and repository access

Treeish reads and writes standard Git repositories. It does not introduce a
package-specific repository format.

Inspect ``Repository/capabilities()`` after opening a repository to determine
whether it is writable and which operations are available. This result reflects
the object format, repository format, extensions, and storage features actually
present in that repository. Unknown required extensions or unsupported mutation
formats make the repository read-only or metadata-only rather than risking
corruption.
