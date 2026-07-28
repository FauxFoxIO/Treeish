# ``Treeish``

Read, create, and modify canonical Git repositories through structured,
concurrent Swift APIs.

Treeish keeps credentials and product policy outside the package, validates
repository capabilities before mutation, and exposes byte-aware Git values.

## Overview

Use ``TreeishRoot`` to grant access to a bounded part of the filesystem, then
use ``Treeish`` to discover, open, initialize, or clone a repository. An open
``Repository`` reports the capabilities of the repository it found and exposes
typed Git operations.

Long-running and mutating work returns a ``GitOperation``. Each operation
provides an asynchronous progress stream, supports cancellation, and produces a
typed result.

## Topics

### Opening repositories

- ``TreeishRoot``
- ``TreeishRootPolicy``
- ``Treeish``
- ``Repository``
- ``RepositoryLocation``
- ``RepositoryOpenOptions``
- ``RepositoryInitialization``

### Repository state

- ``RepositorySnapshot``
- ``RepositoryCapabilities``
- ``RepositoryAccess``
- ``RepositoryOperationCapability``
- ``GitConfigurationKey``
- ``GitConfigurationEntry``
- ``GitConfigurationSetRequest``
- ``GitConfigurationUnsetRequest``
- ``Status``
- ``StatusEntry``
- ``StatusChangeKind``
- ``StatusOptions``
- ``ReflogEntry``
- ``ReflogMetadata``
- ``RepositoryIntegrityOptions``
- ``RepositoryIntegrityReport``
- ``RepositoryIntegrityIssue``
- ``GitTreeListingOptions``
- ``GitTreeEntryInfo``
- ``GitTreeEntryMode``

### Operations

- ``GitOperation``
- ``GitProgressEvent``
- ``GitProgressPhase``
- ``GitDiagnostic``

### Git values

- ``GitPath``
- ``GitPathspec``
- ``RefName``
- ``ObjectID``
- ``ObjectHashAlgorithm``

### Remotes

- ``RemoteURL``
- ``GitRemoteTransport``
- ``RepositoryServices``
- ``GitObjectSigner``
- ``GitObjectSignatureVerifier``
- ``GitSigningOptions``
- ``GitSignedObject``
- ``GitSignatureVerification``
- ``GitCredentialProvider``
- ``SSHGitTransport``
- ``SSHGitSession``
- ``SSHGitSessionRequest``
- ``SSHRemoteEndpoint``
- ``SSHGitService``
- ``FetchRequest``
- ``PushRequest``
- ``CloneRequest``
- ``CloneMode``

### Compatibility and safety

- <doc:Compatibility>
