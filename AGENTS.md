# Repository Guidelines

## Project Summary

- Treeish is a standalone open-source native Swift implementation of Git.
- Treeish reads and writes real interoperable Git repositories without libgit2 and without launching a `git` subprocess in production.
- The public library product and import name are `Treeish`.
- Flow lives at `../Flow` and consumes Treeish through structured Swift APIs. Treeish must remain independent of Flow, Mirage, Echo, agent concepts, UI, and product policy.

## Core Rules

- Ground every proposal, diagnosis, and implementation decision in Git's published formats/protocols, system-Git behavior, repository fixtures, tests, or inspected code.
- Preserve canonical Git interoperability. Do not create a Treeish-specific replacement repository format.
- Unknown required repository extensions, object formats, index features, or mutation semantics must disable mutation safely.
- Reading support may be broader than writing support. Never write a feature until Treeish can validate and recover its complete mutation path.
- Structured Swift operations are the source of truth. CLI parsing, terminal rendering, and Flow integration are adapters.
- Keep repository paths and object payloads byte-aware where Git does not guarantee Unicode.
- Treat all repository-controlled bytes as untrusted. Bound allocations, recursion, delta depth, decompression, traversal, and protocol framing.
- Use root-scoped filesystem capabilities, containment checks, lockfiles, atomic replacement, quarantine, and recoverable transaction state for mutations.
- Never run destructive tests against a developer repository. Create isolated temporary repositories and preserve failing fixtures when useful for diagnosis.
- Do not introduce third-party dependencies without explicit approval.
- Comments and documentation describe enduring behavior and rationale in present tense, not change history or conversation history.

## Prerelease Cutover Policy

- Treeish is prerelease software.
- Do not build migrations, compatibility adapters, deprecated aliases, dual-read/dual-write paths, or fallbacks for Treeish's own unreleased Swift APIs and internal metadata.
- Make hard cutovers: update all source, fixtures, tests, and the Flow integration together when necessary, then remove the replaced path completely.
- This rule remains in force until the repository owner explicitly removes or changes it.
- The hard-cutover rule never permits breaking standard Git repository compatibility. On-disk Git formats and network protocols follow their published compatibility rules.

## Architecture Boundaries

- Treeish owns repository discovery, config, objects, packs, indexes, refs, revision resolution, status, diff, checkout, commits, branches, tags, merges, conflicts, rebases, cherry-picks, worktrees, smart HTTP, and optional SSH integration.
- Treeish does not own credentials. It requests scoped authentication and host-key decisions through host-provided challenge APIs.
- Treeish does not own agent writer leases, approvals, session persistence, handoff, tool schemas, or shell command presentation.
- System Git is the compatibility oracle in development and CI, not a production backend.
- The temporary implementation handoff belongs at `.codex/tmp/architecture-plan-treeish.md`. Keep it untracked, update it when evidence changes the architecture, and remove it after implementation is complete or abandoned.

## Swift Standards

- Align Apple deployment floors with Flow: iOS 17.4 and macOS 14 unless the architecture explicitly changes.
- Use Swift 6 strict concurrency.
- Public values are `Sendable`.
- Actor or transaction ownership must follow actual repository mutation boundaries rather than wrapping every operation in one global lock.
- Keep blocking and high-volume filesystem, compression, graph, and network work off the main actor.
- Avoid force unwraps and force `try` unless malformed state cannot be represented safely.
- Prefer one primary type per file and focused internal targets behind one curated public product.
- Use Swift Testing for new tests.

## Compatibility and Verification

- Build bidirectional fixtures: system Git opens and mutates Treeish repositories, and Treeish opens and mutates system-Git repositories.
- Verify loose-object bytes, object IDs, trees, commits, tags, refs, reflogs, indexes, packs, deltas, pkt-lines, negotiation, checkout, and conflict states.
- Fuzz and truncate configs, objects, indexes, packs, deltas, refs, and protocol messages.
- Test cancellation and crash recovery before, during, and after every atomic publication boundary.
- Use quarantine for received objects and publish refs only after reachability and checksum validation.
- Record supported read/write features in a machine-readable capability matrix.

## Codex-Specific Guidance

- Use `$architecture-plan-reference` only when the user explicitly names or invokes it.
- Use subagents for bounded parallel research or implementation work when explicitly requested or when repository-local instructions require them.
