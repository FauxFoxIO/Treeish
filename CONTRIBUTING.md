# Contributing to Treeish

Thanks for helping improve Treeish.

## Development requirements

- macOS with the current Xcode toolchain
- Swift 6.2 or newer
- Git, used only by interoperability tests and fixture tooling

Clone the repository and validate the package:

```sh
git clone https://github.com/FauxFoxIO/Treeish.git
cd Treeish
Scripts/validate-package.sh
swift test
```

## Project boundaries

Treeish is a native Swift implementation of Git. Production targets must:

- read and write canonical Git formats;
- contain Swift source only;
- never launch `git` or another subprocess;
- remain independent of Flow, Mirage, Echo, UI frameworks, and product policy;
- keep credentials behind host-provided challenge APIs; and
- fail closed for mutation when required repository features are unsupported.

System Git is the interoperability oracle in tests, not a production backend.
Do not run destructive tests against an existing developer repository.

## Making changes

1. Add or update Swift Testing coverage for observable behavior.
2. Add bidirectional system-Git coverage when a change affects repository
   formats, protocols, references, indexes, worktrees, or object storage.
3. Keep untrusted-input parsing bounded by `TreeishResourceLimits`.
4. Update `compatibility.json`, the README, and DocC when support changes.
5. Run the validation script and complete test suite.

Keep pull requests focused and explain the Git behavior or published format that
supports the implementation. New third-party dependencies require maintainer
approval.

## Commit and pull request hygiene

- Do not commit credentials, private repository data, generated build products,
  `.swiftpm`, or `.build`.
- Do not rewrite unrelated code or discard another contributor’s changes.
- Use present-tense comments that explain enduring behavior and rationale.
- Include reproduction steps for bug fixes and note any intentional difference
  from system Git.
