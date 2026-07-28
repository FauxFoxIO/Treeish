import Foundation
import TreeishCore

public struct RepositoryLocation: Sendable, Hashable, Codable {
    public let worktreePath: GitPath?
    public let gitDirectoryPath: GitPath
    public let commonDirectoryPath: GitPath
    public let objectDirectoryPath: GitPath
    public let isBare: Bool

    public init(
        worktreePath: GitPath?,
        gitDirectoryPath: GitPath,
        commonDirectoryPath: GitPath,
        objectDirectoryPath: GitPath,
        isBare: Bool
    ) {
        self.worktreePath = worktreePath
        self.gitDirectoryPath = gitDirectoryPath
        self.commonDirectoryPath = commonDirectoryPath
        self.objectDirectoryPath = objectDirectoryPath
        self.isBare = isBare
    }
}

public struct RepositoryOpenOptions: Sendable, Hashable, Codable {
    public var resourceLimits: TreeishResourceLimits

    public init(resourceLimits: TreeishResourceLimits = .init()) {
        self.resourceLimits = resourceLimits
    }
}

public struct RepositoryInitialization: Sendable, Hashable, Codable {
    public var bare: Bool
    public var initialBranch: String
    public var objectFormat: ObjectHashAlgorithm
    public var refStorage: RefStorageFormat

    public init(
        bare: Bool = false,
        initialBranch: String = "main",
        objectFormat: ObjectHashAlgorithm = .sha1,
        refStorage: RefStorageFormat = .files
    ) {
        self.bare = bare
        self.initialBranch = initialBranch
        self.objectFormat = objectFormat
        self.refStorage = refStorage
    }
}

public struct RepositoryIdentity: Sendable, Hashable, Codable {
    public let root: TreeishRootIdentity
    public let location: RepositoryLocation

    public init(root: TreeishRootIdentity, location: RepositoryLocation) {
        self.root = root
        self.location = location
    }
}

public struct RepositorySnapshot: Sendable, Hashable, Codable {
    public let headReference: RefName?
    public let headObjectID: ObjectID?
    public let capabilities: RepositoryCapabilities

    public init(
        headReference: RefName?,
        headObjectID: ObjectID?,
        capabilities: RepositoryCapabilities
    ) {
        self.headReference = headReference
        self.headObjectID = headObjectID
        self.capabilities = capabilities
    }
}

public struct CommitRequest: Sendable, Hashable {
    public let tree: ObjectID
    public let parents: [ObjectID]
    public let expectedHead: ObjectID?
    public let author: Signature
    public let committer: Signature
    public let message: [UInt8]

    public init(
        tree: ObjectID,
        parents: [ObjectID] = [],
        expectedHead: ObjectID? = nil,
        author: Signature,
        committer: Signature,
        message: [UInt8]
    ) {
        self.tree = tree
        self.parents = parents
        self.expectedHead = expectedHead
        self.author = author
        self.committer = committer
        self.message = message
    }
}

public struct Signature: Sendable, Hashable, Codable {
    public let name: String
    public let email: String
    public let secondsSinceEpoch: Int64
    public let timeZoneOffsetMinutes: Int

    public init(
        name: String,
        email: String,
        secondsSinceEpoch: Int64,
        timeZoneOffsetMinutes: Int
    ) {
        self.name = name
        self.email = email
        self.secondsSinceEpoch = secondsSinceEpoch
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
    }
}

public struct CommitResult: Sendable, Hashable, Codable {
    public let objectID: ObjectID
    public let updatedReference: RefName

    public init(objectID: ObjectID, updatedReference: RefName) {
        self.objectID = objectID
        self.updatedReference = updatedReference
    }
}

public struct RefUpdateResult: Sendable, Hashable, Codable {
    public let name: RefName
    public let previous: ObjectID?
    public let current: ObjectID

    public init(name: RefName, previous: ObjectID?, current: ObjectID) {
        self.name = name
        self.previous = previous
        self.current = current
    }
}

public struct ReferenceInfo: Sendable, Hashable, Codable {
    public let name: RefName
    public let objectID: ObjectID

    public init(name: RefName, objectID: ObjectID) {
        self.name = name
        self.objectID = objectID
    }
}

public struct TagRequest: Sendable, Hashable {
    public let name: String
    public let target: ObjectID
    public let tagger: Signature?
    public let message: [UInt8]?

    public init(name: String, target: ObjectID, tagger: Signature? = nil, message: [UInt8]? = nil) {
        self.name = name
        self.target = target
        self.tagger = tagger
        self.message = message
    }
}

public struct ReflogMetadata: Sendable, Hashable, Codable {
    public let signature: Signature
    public let message: String

    public init(signature: Signature, message: String) {
        self.signature = signature
        self.message = message
    }
}

public struct ReflogEntry: Sendable, Hashable, Codable {
    public let previous: ObjectID
    public let current: ObjectID
    public let committer: Signature
    public let message: String

    public init(
        previous: ObjectID,
        current: ObjectID,
        committer: Signature,
        message: String
    ) {
        self.previous = previous
        self.current = current
        self.committer = committer
        self.message = message
    }
}

public struct CheckoutRequest: Sendable, Hashable, Codable {
    public let commit: ObjectID
    public let reference: RefName?
    public let force: Bool
    public let reflog: ReflogMetadata?

    public init(
        commit: ObjectID,
        reference: RefName? = nil,
        force: Bool = false,
        reflog: ReflogMetadata? = nil
    ) {
        self.commit = commit
        self.reference = reference
        self.force = force
        self.reflog = reflog
    }
}

public struct CheckoutResult: Sendable, Hashable, Codable {
    public let commit: ObjectID
    public let reference: RefName?
    public let pathsWritten: Int

    public init(commit: ObjectID, reference: RefName?, pathsWritten: Int) {
        self.commit = commit
        self.reference = reference
        self.pathsWritten = pathsWritten
    }
}

public enum ResetMode: String, Sendable, Hashable, Codable {
    case soft
    case mixed
    case hard
}

public struct ResetRequest: Sendable, Hashable, Codable {
    public let commit: ObjectID
    public let mode: ResetMode
    public let reflog: ReflogMetadata?

    public init(
        commit: ObjectID,
        mode: ResetMode = .mixed,
        reflog: ReflogMetadata? = nil
    ) {
        self.commit = commit
        self.mode = mode
        self.reflog = reflog
    }
}

public struct RestoreRequest: Sendable, Hashable, Codable {
    public let pathspecs: [GitPathspec]
    public let source: ObjectID?
    public let restoreIndex: Bool
    public let restoreWorktree: Bool

    public init(
        pathspecs: [GitPathspec],
        source: ObjectID? = nil,
        restoreIndex: Bool = false,
        restoreWorktree: Bool = true
    ) {
        self.pathspecs = pathspecs
        self.source = source
        self.restoreIndex = restoreIndex
        self.restoreWorktree = restoreWorktree
    }
}

public struct ApplyPatchRequest: Sendable, Hashable, Codable {
    public let patch: [UInt8]
    public let updateIndex: Bool
    public let updateWorktree: Bool
    public let maximumOffsetSearch: Int

    public init(
        patch: [UInt8],
        updateIndex: Bool = false,
        updateWorktree: Bool = true,
        maximumOffsetSearch: Int = 1_000
    ) {
        self.patch = patch
        self.updateIndex = updateIndex
        self.updateWorktree = updateWorktree
        self.maximumOffsetSearch = maximumOffsetSearch
    }
}

public struct ApplyPatchResult: Sendable, Hashable, Codable {
    public let updated: [GitPath]
    public let deleted: [GitPath]

    public init(updated: [GitPath], deleted: [GitPath]) {
        self.updated = updated
        self.deleted = deleted
    }
}

public struct BundleArchive: Sendable, Hashable, Codable {
    public let bytes: [UInt8]
    public let references: [RefName: ObjectID]

    public init(bytes: [UInt8], references: [RefName: ObjectID]) {
        self.bytes = bytes
        self.references = references
    }
}

public struct BundleImportResult: Sendable, Hashable, Codable {
    public let receivedObjects: Int
    public let references: [RefName: ObjectID]

    public init(receivedObjects: Int, references: [RefName: ObjectID]) {
        self.receivedObjects = receivedObjects
        self.references = references
    }
}

public struct MergeRequest: Sendable, Hashable {
    public let other: ObjectID
    public let author: Signature
    public let committer: Signature
    public let message: [UInt8]

    public init(
        other: ObjectID,
        author: Signature,
        committer: Signature,
        message: [UInt8]
    ) {
        self.other = other
        self.author = author
        self.committer = committer
        self.message = message
    }
}

public enum MergeResult: Sendable, Hashable, Codable {
    case alreadyUpToDate(ObjectID)
    case fastForward(from: ObjectID, to: ObjectID)
    case merged(ObjectID)
    case conflicted([GitPath])
}

public struct MergeContinuationRequest: Sendable, Hashable {
    public let author: Signature
    public let committer: Signature
    public let message: [UInt8]?

    public init(author: Signature, committer: Signature, message: [UInt8]? = nil) {
        self.author = author
        self.committer = committer
        self.message = message
    }
}

public struct CherryPickRequest: Sendable, Hashable {
    public let commit: ObjectID
    public let author: Signature
    public let committer: Signature
    public let message: [UInt8]?

    public init(
        commit: ObjectID,
        author: Signature,
        committer: Signature,
        message: [UInt8]? = nil
    ) {
        self.commit = commit
        self.author = author
        self.committer = committer
        self.message = message
    }
}

public enum CherryPickResult: Sendable, Hashable, Codable {
    case committed(ObjectID)
    case conflicted([GitPath])
}

public struct RebaseRequest: Sendable, Hashable {
    public let onto: ObjectID
    public let commits: [ObjectID]
    public let author: Signature
    public let committer: Signature

    public init(onto: ObjectID, commits: [ObjectID], author: Signature, committer: Signature) {
        self.onto = onto
        self.commits = commits
        self.author = author
        self.committer = committer
    }
}

public enum RebaseResult: Sendable, Hashable, Codable {
    case completed(ObjectID)
    case conflicted(commit: ObjectID, paths: [GitPath])
}

public struct WorkspaceStateBlob: Sendable, Hashable, Codable {
    public let identifier: [UInt8]
    public let bytes: [UInt8]

    public init(identifier: [UInt8], bytes: [UInt8]) {
        self.identifier = identifier
        self.bytes = bytes
    }
}

public struct WorkspaceStateEntry: Sendable, Hashable, Codable {
    public let path: GitPath
    public let mode: UInt32
    public let contentIdentifier: [UInt8]

    public init(path: GitPath, mode: UInt32, contentIdentifier: [UInt8]) {
        self.path = path
        self.mode = mode
        self.contentIdentifier = contentIdentifier
    }
}

public struct WorkspaceState: Sendable, Hashable, Codable {
    public let headReference: RefName?
    public let headObjectID: ObjectID?
    public let indexBytes: [UInt8]
    public let entries: [WorkspaceStateEntry]
    public let blobs: [WorkspaceStateBlob]

    public init(
        headReference: RefName?,
        headObjectID: ObjectID?,
        indexBytes: [UInt8],
        entries: [WorkspaceStateEntry],
        blobs: [WorkspaceStateBlob]
    ) {
        self.headReference = headReference
        self.headObjectID = headObjectID
        self.indexBytes = indexBytes
        self.entries = entries
        self.blobs = blobs
    }
}

public struct StageRequest: Sendable, Hashable, Codable {
    public let pathspecs: [GitPathspec]
    public let forceIgnored: Bool
    public let includeSparsePaths: Bool

    public init(
        pathspecs: [GitPathspec],
        forceIgnored: Bool = false,
        includeSparsePaths: Bool = false
    ) {
        self.pathspecs = pathspecs
        self.forceIgnored = forceIgnored
        self.includeSparsePaths = includeSparsePaths
    }
}

public struct IndexUpdate: Sendable, Hashable, Codable {
    public let addedOrUpdated: [GitPath]
    public let removed: [GitPath]

    public init(addedOrUpdated: [GitPath], removed: [GitPath]) {
        self.addedOrUpdated = addedOrUpdated
        self.removed = removed
    }
}

public struct StatusOptions: Sendable, Hashable, Codable {
    public var includeUntracked: Bool
    public var includeIgnored: Bool

    public init(
        includeUntracked: Bool = true,
        includeIgnored: Bool = false
    ) {
        self.includeUntracked = includeUntracked
        self.includeIgnored = includeIgnored
    }
}

public struct SubmoduleConfiguration: Sendable, Hashable, Codable {
    public let name: String
    public let path: GitPath
    public let url: String?
    public let branch: String?
    public let update: String?
    public let ignore: String?

    public init(
        name: String,
        path: GitPath,
        url: String?,
        branch: String?,
        update: String?,
        ignore: String?
    ) {
        self.name = name
        self.path = path
        self.url = url
        self.branch = branch
        self.update = update
        self.ignore = ignore
    }
}

public enum SubmoduleState: String, Sendable, Hashable, Codable {
    case uninitialized
    case clean
    case modified
    case differentCommit
    case missingGitlink
    case unconfigured
}

public struct SubmoduleStatus: Sendable, Hashable, Codable {
    public let configuration: SubmoduleConfiguration?
    public let path: GitPath
    public let expectedCommit: ObjectID?
    public let checkedOutCommit: ObjectID?
    public let state: SubmoduleState

    public init(
        configuration: SubmoduleConfiguration?,
        path: GitPath,
        expectedCommit: ObjectID?,
        checkedOutCommit: ObjectID?,
        state: SubmoduleState
    ) {
        self.configuration = configuration
        self.path = path
        self.expectedCommit = expectedCommit
        self.checkedOutCommit = checkedOutCommit
        self.state = state
    }
}

public struct SubmoduleUpdateRequest: Sendable, Hashable, Codable {
    public let paths: [GitPath]
    public let initialize: Bool
    public let fetch: Bool
    public let force: Bool
    public let recursive: Bool
    public let maximumDepth: Int

    public init(
        paths: [GitPath] = [],
        initialize: Bool = true,
        fetch: Bool = true,
        force: Bool = false,
        recursive: Bool = false,
        maximumDepth: Int = 16
    ) {
        self.paths = paths
        self.initialize = initialize
        self.fetch = fetch
        self.force = force
        self.recursive = recursive
        self.maximumDepth = maximumDepth
    }
}

public enum StatusChangeKind: String, Sendable, Hashable, Codable {
    case added
    case modified
    case deleted
    case typeChanged
    case untracked
    case ignored
    case unmerged
}

public struct StatusEntry: Sendable, Hashable, Codable {
    public let path: GitPath
    public let indexChange: StatusChangeKind?
    public let worktreeChange: StatusChangeKind?

    public init(
        path: GitPath,
        indexChange: StatusChangeKind? = nil,
        worktreeChange: StatusChangeKind? = nil
    ) {
        self.path = path
        self.indexChange = indexChange
        self.worktreeChange = worktreeChange
    }
}

public struct Status: Sendable, Hashable, Codable {
    public let entries: [StatusEntry]

    public init(entries: [StatusEntry]) {
        self.entries = entries
    }

    public var isClean: Bool { entries.isEmpty }
}

public struct CommitInfo: Sendable, Hashable {
    public let objectID: ObjectID
    public let tree: ObjectID
    public let parents: [ObjectID]
    public let authorTime: Int64?
    public let message: [UInt8]
}

public struct RevisionRange: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case exclusion
        case symmetricDifference
    }

    public let left: ObjectID
    public let right: ObjectID
    public let kind: Kind

    public init(left: ObjectID, right: ObjectID, kind: Kind) {
        self.left = left
        self.right = right
        self.kind = kind
    }
}

public enum BlobDiffLine: Sendable, Hashable {
    case context([UInt8])
    case deletion([UInt8])
    case insertion([UInt8])
}

public enum BlobDiff: Sendable, Hashable {
    case identical
    case binary(oldBytes: Int, newBytes: Int)
    case text([BlobDiffLine])
}

public struct WorktreeRequest: Sendable, Hashable {
    public let destination: GitPath
    public let start: ObjectID
    public let branch: RefName?

    public init(destination: GitPath, start: ObjectID, branch: RefName? = nil) {
        self.destination = destination
        self.start = start
        self.branch = branch
    }
}

public struct WorktreeResult: Sendable, Hashable, Codable {
    public let identifier: String
    public let path: GitPath
    public let head: ObjectID

    public init(identifier: String, path: GitPath, head: ObjectID) {
        self.identifier = identifier
        self.path = path
        self.head = head
    }
}

public struct LinkedWorktreeInfo: Sendable, Hashable, Codable {
    public let identifier: String
    public let path: GitPath
    public let head: ObjectID
    public let lockedReason: String?

    public init(identifier: String, path: GitPath, head: ObjectID, lockedReason: String?) {
        self.identifier = identifier
        self.path = path
        self.head = head
        self.lockedReason = lockedReason
    }
}
