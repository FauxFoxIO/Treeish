# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through
[GitHub Security Advisories](https://github.com/FauxFoxIO/Treeish/security/advisories/new).
Do not open a public issue before the report has been assessed.

Include the affected revision, impact, and a minimal reproduction when possible.
Do not include credentials, private repository contents, access tokens, or
unredacted private remote URLs.

## Security model

Treeish treats repository files, object data, packfiles, configuration, refs,
and protocol responses as untrusted input. Parsers bound allocation, recursion,
decompression, delta depth, traversal, and protocol framing. Mutations use
root-scoped filesystem access, validation, lockfiles, and recoverable
transactions.

Unknown required repository features fail closed for mutation.
