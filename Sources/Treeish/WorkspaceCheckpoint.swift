import Foundation
import TreeishCore
import TreeishFileSystem
import TreeishGraph
import TreeishIndex
import TreeishObjects
import TreeishPacks

private struct WorkspaceCheckpointIndexKey: Hashable {
    let path: [UInt8]
    let stage: UInt8
}

private struct WorkspaceCheckpointHeadIdentity: Equatable {
    let reference: RefName?
    let objectID: ObjectID?
    let bytes: [UInt8]?
}

private struct WorkspaceCheckpointRepositorySnapshot: Equatable {
    let head: WorkspaceCheckpointHeadIdentity
    let indexBytes: [UInt8]?
}

private struct WorkspaceCheckpointOverlayInventoryEntry: Equatable {
    let path: GitPath
    let kind: GitWorkspaceCheckpointOverlayKind
    let origin: GitWorkspaceCheckpointOverlayOrigin
    let mode: UInt32
    let contentByteCount: Int
    let contentDigest: [UInt8]?
}

private struct WorkspaceCheckpointOverlayCaptureEntry {
    let inventory: WorkspaceCheckpointOverlayInventoryEntry
    let payload: [UInt8]?
}

struct WorkspaceCheckpointRepositoryContext: Sendable {
    let root: TreeishRoot
    let gitDirectory: RootDirectory
    let commonDirectory: RootDirectory
    let objectStore: RepositoryObjectStore
    let indexStore: GitIndexStore
    let worktree: RootDirectory?
    let access: RepositoryAccess
    let mutationReason: CapabilityReason?
    let resourceLimits: TreeishResourceLimits
}

/// Errors raised while validating or moving a workspace checkpoint.
public enum GitWorkspaceCheckpointError: Error, Sendable, Equatable {
    case unsupportedSchema(Int)
    case invalidManifest
    case objectFormatMismatch
    case invalidChunk
    case incompleteObject(ObjectID)
    case unsafeDestination
    case destinationIsActive
    case destinationIsNotLinkedWorktree
    case destinationGenerationMismatch(expected: ObjectID?, actual: ObjectID?)
    case unsupportedOperationContinuation
    /// A bounded validation pass observed a changing worktree, index, or HEAD.
    /// The caller may retry later; no checkpoint objects were written.
    case changedDuringCapture
    /// Treeish can preserve an absent HEAD state but cannot create it in a
    /// newly initialized Git repository without inventing a reference.
    case unsupportedUnbornHead
}

/// Controls whether ignored worktree entries are part of a checkpoint.
public enum GitWorkspaceCheckpointIgnoredFiles: String, Sendable, Hashable, Codable {
    /// Ignore rules are recorded as policy, but ignored filesystem entries are omitted.
    case exclude

    /// Ignored filesystem entries are captured alongside untracked entries.
    case include
}

/// Treeish does not serialize in-progress operations because their continuation
/// state is repository-private and cannot be reconstructed faithfully.
public enum GitWorkspaceCheckpointOperationContinuation: String, Sendable, Hashable, Codable {
    case unavailable
}

/// A logical index entry. Stat cache fields are intentionally omitted because
/// they are advisory and are invalid after moving to another filesystem.
public struct GitWorkspaceCheckpointIndexEntry: Sendable, Hashable, Codable {
    public let path: GitPath
    public let objectID: ObjectID
    public let mode: UInt32
    public let stage: UInt8
    public let assumeValid: Bool
    public let skipWorktree: Bool
    public let intentToAdd: Bool

    public init(
        path: GitPath,
        objectID: ObjectID,
        mode: UInt32,
        stage: UInt8,
        assumeValid: Bool,
        skipWorktree: Bool,
        intentToAdd: Bool
    ) throws {
        guard stage <= 3 else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
        self.path = path
        self.objectID = objectID
        self.mode = mode
        self.stage = stage
        self.assumeValid = assumeValid
        self.skipWorktree = skipWorktree
        self.intentToAdd = intentToAdd
    }
}

public enum GitWorkspaceCheckpointOverlayKind: String, Sendable, Hashable, Codable {
    case regularFile
    case symbolicLink
    case directory
}

public enum GitWorkspaceCheckpointOverlayOrigin: String, Sendable, Hashable, Codable {
    case tracked
    case untracked
    case ignored
}

/// A complete filesystem entry in the checkpoint's worktree view.
///
/// File and symlink content uses ordinary Git blobs. Directories retain empty
/// directories that Git itself would otherwise omit.
public struct GitWorkspaceCheckpointOverlayEntry: Sendable, Hashable, Codable {
    public let path: GitPath
    public let kind: GitWorkspaceCheckpointOverlayKind
    public let origin: GitWorkspaceCheckpointOverlayOrigin
    public let mode: UInt32
    public let contentObjectID: ObjectID?

    public init(
        path: GitPath,
        kind: GitWorkspaceCheckpointOverlayKind,
        origin: GitWorkspaceCheckpointOverlayOrigin,
        mode: UInt32,
        contentObjectID: ObjectID?
    ) throws {
        switch kind {
        case .regularFile:
            guard mode == 0o100644 || mode == 0o100755,
                  contentObjectID != nil else {
                throw GitWorkspaceCheckpointError.invalidManifest
            }
        case .symbolicLink:
            guard mode == 0o120000, contentObjectID != nil else {
                throw GitWorkspaceCheckpointError.invalidManifest
            }
        case .directory:
            guard mode == 0o040000, contentObjectID == nil else {
                throw GitWorkspaceCheckpointError.invalidManifest
            }
        }
        self.path = path
        self.kind = kind
        self.origin = origin
        self.mode = mode
        self.contentObjectID = contentObjectID
    }
}

/// A checkpoint's HEAD state. An attached HEAD without an object is an unborn
/// branch; a detached HEAD always has a resolved object. `unborn` retains the
/// rare repository state in which Git has no symbolic or direct HEAD value.
public enum GitWorkspaceCheckpointHead: Sendable, Hashable, Codable {
    case attached(reference: RefName, objectID: ObjectID?)
    case detached(objectID: ObjectID)
    case unborn(reference: RefName?)
}

/// Capture limits for a checkpoint. Limits are independent from repository
/// object limits so callers can choose a tighter handoff budget.
public struct GitWorkspaceCheckpointCaptureOptions: Sendable, Hashable, Codable {
    public var ignoredFiles: GitWorkspaceCheckpointIgnoredFiles
    public var maximumEntries: Int
    public var maximumObjects: Int
    public var maximumOverlayBytes: Int

    public init(
        ignoredFiles: GitWorkspaceCheckpointIgnoredFiles = .include,
        maximumEntries: Int = 1_000_000,
        maximumObjects: Int = 1_000_000,
        maximumOverlayBytes: Int = 512 * 1024 * 1024
    ) {
        self.ignoredFiles = ignoredFiles
        self.maximumEntries = maximumEntries
        self.maximumObjects = maximumObjects
        self.maximumOverlayBytes = maximumOverlayBytes
    }
}

/// Transfer limits for the bounded object-payload chunks used by export and import.
public struct GitWorkspaceCheckpointTransferOptions: Sendable, Hashable, Codable {
    public var maximumChunkBytes: Int
    public var maximumObjects: Int
    public var maximumTransferBytes: Int

    public init(
        maximumChunkBytes: Int = 1 * 1024 * 1024,
        maximumObjects: Int = 1_000_000,
        maximumTransferBytes: Int = 2 * 1024 * 1024 * 1024
    ) {
        self.maximumChunkBytes = maximumChunkBytes
        self.maximumObjects = maximumObjects
        self.maximumTransferBytes = maximumTransferBytes
    }
}

/// A bounded part of one Git object's payload.
///
/// `contentDigest` hashes this chunk, while `objectID` hashes the canonical Git
/// object once all chunks have been reassembled.
public struct GitWorkspaceCheckpointObjectChunk: Sendable, Hashable, Codable {
    public let objectID: ObjectID
    public let objectType: GitObjectKind
    public let objectByteCount: Int
    public let byteOffset: Int
    public let bytes: [UInt8]
    public let contentDigest: [UInt8]

    public init(
        objectID: ObjectID,
        objectType: GitObjectKind,
        objectByteCount: Int,
        byteOffset: Int,
        bytes: [UInt8],
        contentDigest: [UInt8]? = nil
    ) throws {
        guard objectByteCount >= 0,
              byteOffset >= 0,
              byteOffset <= objectByteCount,
              bytes.count <= objectByteCount - byteOffset else {
            throw GitWorkspaceCheckpointError.invalidChunk
        }
        let digest = contentDigest ?? SHA256.hash(bytes)
        guard digest.count == GitHashAlgorithm.sha256.byteCount,
              SHA256.hash(bytes) == digest else {
            throw GitWorkspaceCheckpointError.invalidChunk
        }
        self.objectID = objectID
        self.objectType = objectType
        self.objectByteCount = objectByteCount
        self.byteOffset = byteOffset
        self.bytes = bytes
        self.contentDigest = digest
    }
}

public struct GitWorkspaceCheckpointImportResult: Sendable, Hashable, Codable {
    public let importedObjectIDs: [ObjectID]
    public let missingObjectIDs: [ObjectID]

    public init(importedObjectIDs: [ObjectID], missingObjectIDs: [ObjectID]) {
        self.importedObjectIDs = importedObjectIDs
        self.missingObjectIDs = missingObjectIDs
    }
}

/// A verified receipt for a new or already-provisioned checkpoint destination.
public struct GitWorkspaceCheckpointMaterializationResult: Sendable, Hashable, Codable {
    public let location: RepositoryLocation
    public let operationContinuation: GitWorkspaceCheckpointOperationContinuation

    public init(
        location: RepositoryLocation,
        operationContinuation: GitWorkspaceCheckpointOperationContinuation
    ) {
        self.location = location
        self.operationContinuation = operationContinuation
    }
}

/// An immutable, Git-native workspace checkpoint.
///
/// The manifest is format version 1. Objects remain canonical Git objects and
/// can be supplied independently through `GitWorkspaceCheckpointObjectChunk`.
public struct GitWorkspaceCheckpoint: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    private static let maximumManifestEntries = 1_000_000
    private static let maximumManifestObjects = 1_000_000

    public let schemaVersion: Int
    public let objectFormat: ObjectHashAlgorithm
    public let head: GitWorkspaceCheckpointHead
    public let indexVersion: UInt32
    public let indexEntries: [GitWorkspaceCheckpointIndexEntry]
    public let overlayEntries: [GitWorkspaceCheckpointOverlayEntry]
    public let deletedPaths: [GitPath]
    public let ignoredFiles: GitWorkspaceCheckpointIgnoredFiles
    public let objectRoots: [ObjectID]
    public let requiredObjectIDs: [ObjectID]
    public let operationContinuation: GitWorkspaceCheckpointOperationContinuation

    public init(
        schemaVersion: Int = GitWorkspaceCheckpoint.schemaVersion,
        objectFormat: ObjectHashAlgorithm,
        head: GitWorkspaceCheckpointHead,
        indexVersion: UInt32,
        indexEntries: [GitWorkspaceCheckpointIndexEntry],
        overlayEntries: [GitWorkspaceCheckpointOverlayEntry],
        deletedPaths: [GitPath],
        ignoredFiles: GitWorkspaceCheckpointIgnoredFiles,
        objectRoots: [ObjectID],
        requiredObjectIDs: [ObjectID],
        operationContinuation: GitWorkspaceCheckpointOperationContinuation = .unavailable
    ) throws {
        self.schemaVersion = schemaVersion
        self.objectFormat = objectFormat
        self.head = head
        self.indexVersion = indexVersion
        self.indexEntries = indexEntries
        self.overlayEntries = overlayEntries
        self.deletedPaths = deletedPaths
        self.ignoredFiles = ignoredFiles
        self.objectRoots = objectRoots
        self.requiredObjectIDs = requiredObjectIDs
        self.operationContinuation = operationContinuation
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              (2...4).contains(indexVersion),
              indexEntries.count <= Self.maximumManifestEntries,
              overlayEntries.count <= Self.maximumManifestEntries,
              deletedPaths.count <= Self.maximumManifestEntries,
              objectRoots.count <= Self.maximumManifestObjects,
              requiredObjectIDs.count <= Self.maximumManifestObjects,
              operationContinuation == .unavailable else {
            throw GitWorkspaceCheckpointError.unsupportedSchema(schemaVersion)
        }
        switch head {
        case .attached(let reference, let objectID):
            _ = try RefName(validating: reference.bytes)
            if let objectID, objectID.algorithm != objectFormat {
                throw GitWorkspaceCheckpointError.objectFormatMismatch
            }
        case .detached(let objectID):
            guard objectID.algorithm == objectFormat else {
                throw GitWorkspaceCheckpointError.objectFormatMismatch
            }
        case .unborn(let reference):
            if let reference {
                _ = try RefName(validating: reference.bytes)
            }
        }
        guard indexEntries.allSatisfy({
            $0.objectID.algorithm == objectFormat && $0.stage <= 3
        }), overlayEntries.allSatisfy({
            $0.contentObjectID.map { $0.algorithm == objectFormat } ?? true
        }), objectRoots.allSatisfy({
            $0.algorithm == objectFormat
        }), requiredObjectIDs.allSatisfy({
            $0.algorithm == objectFormat
        }) else {
            throw GitWorkspaceCheckpointError.objectFormatMismatch
        }
        for entry in indexEntries {
            _ = try GitPath(bytes: entry.path.bytes)
            _ = try GitWorkspaceCheckpointIndexEntry(
                path: entry.path,
                objectID: entry.objectID,
                mode: entry.mode,
                stage: entry.stage,
                assumeValid: entry.assumeValid,
                skipWorktree: entry.skipWorktree,
                intentToAdd: entry.intentToAdd
            )
        }
        let indexKeys = indexEntries.map {
            WorkspaceCheckpointIndexKey(path: $0.path.bytes, stage: $0.stage)
        }
        guard Set(indexKeys).count == indexKeys.count,
              indexEntries == indexEntries.sorted(by: Self.indexOrdering) else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
        let overlayPaths = overlayEntries.map(\.path.bytes)
        guard Set(overlayPaths).count == overlayPaths.count,
              overlayEntries == overlayEntries.sorted(by: Self.overlayOrdering),
              deletedPaths.map(\.bytes) == deletedPaths.map(\.bytes).sorted(by: Self.pathOrdering),
              Set(deletedPaths.map(\.bytes)).count == deletedPaths.count,
              objectRoots == objectRoots.sorted(by: Self.objectOrdering),
              Set(objectRoots).count == objectRoots.count,
              requiredObjectIDs == requiredObjectIDs.sorted(by: Self.objectOrdering),
              Set(requiredObjectIDs).count == requiredObjectIDs.count,
              Set(objectRoots).isSubset(of: Set(requiredObjectIDs)) else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
        let overlayByPath = Dictionary(uniqueKeysWithValues: overlayEntries.map {
            ($0.path.bytes, $0)
        })
        for entry in overlayEntries {
            _ = try GitPath(bytes: entry.path.bytes)
            _ = try GitWorkspaceCheckpointOverlayEntry(
                path: entry.path,
                kind: entry.kind,
                origin: entry.origin,
                mode: entry.mode,
                contentObjectID: entry.contentObjectID
            )
            if entry.kind != .directory {
                let prefix = entry.path.bytes + [0x2f]
                guard !overlayEntries.contains(where: {
                    $0.path.bytes.starts(with: prefix)
                }) else {
                    throw GitWorkspaceCheckpointError.invalidManifest
                }
            }
        }
        guard deletedPaths.allSatisfy({
            overlayByPath[$0.bytes]?.kind == .directory ||
                overlayByPath[$0.bytes] == nil
        }) else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
        let contentRoots = overlayEntries.compactMap(\.contentObjectID)
        let indexRoots = indexEntries.compactMap { entry -> ObjectID? in
            Self.isNullObjectID(entry.objectID) ? nil : entry.objectID
        }
        let headRoots: [ObjectID] = switch head {
        case .attached(_, let objectID): objectID.map { [$0] } ?? []
        case .detached(let objectID): [objectID]
        case .unborn: []
        }
        guard Set(contentRoots + indexRoots + headRoots).isSubset(
            of: Set(objectRoots)
        ) else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case objectFormat
        case head
        case indexVersion
        case indexEntries
        case overlayEntries
        case deletedPaths
        case ignoredFiles
        case objectRoots
        case requiredObjectIDs
        case operationContinuation
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            objectFormat: try values.decode(
                ObjectHashAlgorithm.self,
                forKey: .objectFormat
            ),
            head: try values.decode(
                GitWorkspaceCheckpointHead.self,
                forKey: .head
            ),
            indexVersion: try values.decode(UInt32.self, forKey: .indexVersion),
            indexEntries: try values.decode(
                [GitWorkspaceCheckpointIndexEntry].self,
                forKey: .indexEntries
            ),
            overlayEntries: try values.decode(
                [GitWorkspaceCheckpointOverlayEntry].self,
                forKey: .overlayEntries
            ),
            deletedPaths: try values.decode([GitPath].self, forKey: .deletedPaths),
            ignoredFiles: try values.decode(
                GitWorkspaceCheckpointIgnoredFiles.self,
                forKey: .ignoredFiles
            ),
            objectRoots: try values.decode([ObjectID].self, forKey: .objectRoots),
            requiredObjectIDs: try values.decode(
                [ObjectID].self,
                forKey: .requiredObjectIDs
            ),
            operationContinuation: try values.decode(
                GitWorkspaceCheckpointOperationContinuation.self,
                forKey: .operationContinuation
            )
        )
    }

    static func indexOrdering(
        _ left: GitWorkspaceCheckpointIndexEntry,
        _ right: GitWorkspaceCheckpointIndexEntry
    ) -> Bool {
        if left.path.bytes == right.path.bytes { return left.stage < right.stage }
        return left.path.bytes.lexicographicallyPrecedes(right.path.bytes)
    }

    static func overlayOrdering(
        _ left: GitWorkspaceCheckpointOverlayEntry,
        _ right: GitWorkspaceCheckpointOverlayEntry
    ) -> Bool {
        left.path.bytes.lexicographicallyPrecedes(right.path.bytes)
    }

    static func pathOrdering(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        left.lexicographicallyPrecedes(right)
    }

    static func objectOrdering(_ left: ObjectID, _ right: ObjectID) -> Bool {
        left.bytes.lexicographicallyPrecedes(right.bytes)
    }

    static func isNullObjectID(_ value: ObjectID) -> Bool {
        value.bytes.allSatisfy { $0 == 0 }
    }
}

extension Repository {
    /// Captures a portable checkpoint without changing ordinary references.
    public func captureWorkspaceCheckpoint(
        _ options: GitWorkspaceCheckpointCaptureOptions = .init()
    ) -> GitOperation<GitWorkspaceCheckpoint> {
        let context = workspaceCheckpointContext()
        return GitOperation(phase: .indexing) {
            guard case .readWrite = context.access else {
                throw TreeishError.mutationDisabled(
                    context.mutationReason ?? .rootIsReadOnly
                )
            }
            guard let worktree = context.worktree else {
                throw TreeishError.repositoryNotFound
            }
            return try WorkspaceCheckpointOperations.capture(
                options: options,
                worktree: worktree,
                headDirectory: context.gitDirectory,
                refsDirectory: context.commonDirectory,
                store: context.objectStore,
                limits: context.resourceLimits
            )
        }
    }

    public func missingWorkspaceCheckpointObjects(
        for checkpoint: GitWorkspaceCheckpoint
    ) -> GitOperation<[ObjectID]> {
        let context = workspaceCheckpointContext()
        return GitOperation(phase: .validating) {
            try WorkspaceCheckpointOperations.missingObjects(
                checkpoint: checkpoint,
                store: context.objectStore
            )
        }
    }

    public func exportWorkspaceCheckpoint(
        _ checkpoint: GitWorkspaceCheckpoint,
        options: GitWorkspaceCheckpointTransferOptions = .init()
    ) -> GitOperation<[GitWorkspaceCheckpointObjectChunk]> {
        let context = workspaceCheckpointContext()
        return GitOperation(phase: .compression) {
            try WorkspaceCheckpointOperations.export(
                checkpoint: checkpoint,
                options: options,
                store: context.objectStore,
                limits: context.resourceLimits
            )
        }
    }

    /// Imports complete bounded objects through the repository's pack quarantine.
    /// The import publishes objects only; it never creates or changes refs.
    public func importWorkspaceCheckpoint(
        _ checkpoint: GitWorkspaceCheckpoint,
        chunks: [GitWorkspaceCheckpointObjectChunk],
        options: GitWorkspaceCheckpointTransferOptions = .init()
    ) -> GitOperation<GitWorkspaceCheckpointImportResult> {
        let context = workspaceCheckpointContext()
        return GitOperation(phase: .quarantining) {
            guard case .readWrite = context.access else {
                throw TreeishError.mutationDisabled(
                    context.mutationReason ?? .rootIsReadOnly
                )
            }
            return try WorkspaceCheckpointOperations.importObjects(
                checkpoint: checkpoint,
                chunks: chunks,
                options: options,
                store: context.objectStore,
                commonDirectory: context.commonDirectory,
                limits: context.resourceLimits
            )
        }
    }

    /// Creates a new repository only in an existing, inactive, empty directory.
    /// Source refs are never changed. In-progress operations remain unavailable.
    public func materializeWorkspaceCheckpoint(
        _ checkpoint: GitWorkspaceCheckpoint,
        at destination: GitPath,
        options: GitWorkspaceCheckpointTransferOptions = .init()
    ) -> GitOperation<GitWorkspaceCheckpointMaterializationResult> {
        let context = workspaceCheckpointContext()
        return GitOperation(phase: .planningCheckout) {
            try await WorkspaceCheckpointOperations.materialize(
                checkpoint: checkpoint,
                destination: destination,
                sourceRoot: context.root,
                sourceStore: context.objectStore,
                limits: context.resourceLimits,
                transferOptions: options
            )
        }
    }

    /// Installs a checkpoint into a clean, already-provisioned worktree.
    ///
    /// `expectedGeneration` must be the worktree's admitted start commit,
    /// normally `WorktreeResult.head` for a linked worktree. Before mutating,
    /// Treeish checks that the destination has that exact HEAD, has no operation
    /// or local changes, and contains no untracked entries. Installation only
    /// changes this worktree's HEAD, index, and files; it never imports objects
    /// or updates shared ordinary references.
    public func installWorkspaceCheckpoint(
        _ checkpoint: GitWorkspaceCheckpoint,
        expectedGeneration: ObjectID
    ) -> GitOperation<GitWorkspaceCheckpointMaterializationResult> {
        let context = workspaceCheckpointContext()
        let location = identity.location
        return GitOperation(phase: .updatingWorktree) {
            guard case .readWrite = context.access else {
                throw TreeishError.mutationDisabled(
                    context.mutationReason ?? .rootIsReadOnly
                )
            }
            guard let worktree = context.worktree else {
                throw TreeishError.repositoryNotFound
            }
            try WorkspaceCheckpointOperations.installIntoCleanWorktree(
                checkpoint: checkpoint,
                expectedGeneration: expectedGeneration,
                indexStore: context.indexStore,
                worktree: worktree,
                headDirectory: context.gitDirectory,
                refsDirectory: context.commonDirectory,
                store: context.objectStore,
                limits: context.resourceLimits
            )
            return GitWorkspaceCheckpointMaterializationResult(
                location: location,
                operationContinuation: .unavailable
            )
        }
    }

    /// Verifies that this worktree is still a clean destination at the exact
    /// admitted generation. Ignored material may remain when the caller's
    /// checkpoint policy excludes it.
    public func validateWorkspaceCheckpointDestination(
        expectedGeneration: ObjectID,
        ignoredFiles: GitWorkspaceCheckpointIgnoredFiles = .exclude
    ) -> GitOperation<Void> {
        let context = workspaceCheckpointContext()
        return GitOperation(phase: .planningCheckout) {
            guard let worktree = context.worktree else {
                throw TreeishError.repositoryNotFound
            }
            _ = try Repository.validateWorkspaceCheckpointCleanDestination(
                expectedGeneration: expectedGeneration,
                ignoredFiles: ignoredFiles,
                indexStore: context.indexStore,
                worktree: worktree,
                headDirectory: context.gitDirectory,
                refsDirectory: context.commonDirectory,
                store: context.objectStore
            )
        }
    }

    /// Replaces a possibly dirty worktree only when its complete checkpointed
    /// state still matches `expectedCurrent`. Ignored files excluded by both
    /// checkpoints are preserved in place and may not collide with replacement
    /// paths. Ordinary references are never updated.
    public func replaceWorkspaceCheckpoint(
        _ expectedCurrent: GitWorkspaceCheckpoint,
        with replacement: GitWorkspaceCheckpoint
    ) -> GitOperation<GitWorkspaceCheckpointMaterializationResult> {
        let context = workspaceCheckpointContext()
        let location = identity.location
        return GitOperation(phase: .updatingWorktree) {
            guard case .readWrite = context.access else {
                throw TreeishError.mutationDisabled(
                    context.mutationReason ?? .rootIsReadOnly
                )
            }
            guard let worktree = context.worktree else {
                throw TreeishError.repositoryNotFound
            }
            try WorkspaceCheckpointOperations.replaceWorktree(
                expectedCurrent: expectedCurrent,
                replacement: replacement,
                indexStore: context.indexStore,
                worktree: worktree,
                headDirectory: context.gitDirectory,
                refsDirectory: context.commonDirectory,
                store: context.objectStore,
                limits: context.resourceLimits
            )
            return GitWorkspaceCheckpointMaterializationResult(
                location: location,
                operationContinuation: .unavailable
            )
        }
    }

    /// Reattaches a detached worktree to an existing branch without changing
    /// the branch or rematerializing the worktree. The detached HEAD and branch
    /// must resolve to the same object, and no other registered worktree may
    /// already have the branch checked out.
    public func attachWorkspaceCheckpointHead(
        reference: RefName,
        expectedObjectID: ObjectID
    ) -> GitOperation<Void> {
        let context = workspaceCheckpointContext()
        return GitOperation(phase: .updatingRefs) {
            guard case .readWrite = context.access else {
                throw TreeishError.mutationDisabled(
                    context.mutationReason ?? .rootIsReadOnly
                )
            }
            guard context.worktree != nil else {
                throw TreeishError.repositoryNotFound
            }
            try Repository.attachWorkspaceCheckpointHead(
                headDirectory: context.gitDirectory,
                refsDirectory: context.commonDirectory,
                reference: reference,
                expectedObjectID: expectedObjectID
            )
        }
    }

    func installWorkspaceCheckpoint(
        _ checkpoint: GitWorkspaceCheckpoint
    ) -> GitOperation<Void> {
        let context = workspaceCheckpointContext()
        return GitOperation(phase: .updatingWorktree) {
            guard case .readWrite = context.access else {
                throw TreeishError.mutationDisabled(
                    context.mutationReason ?? .rootIsReadOnly
                )
            }
            guard let worktree = context.worktree else {
                throw TreeishError.repositoryNotFound
            }
            try WorkspaceCheckpointOperations.install(
                checkpoint: checkpoint,
                indexStore: context.indexStore,
                worktree: worktree,
                headDirectory: context.gitDirectory,
                refsDirectory: context.commonDirectory,
                store: context.objectStore
            )
        }
    }
}

enum WorkspaceCheckpointOperations {
    static func capture(
        options: GitWorkspaceCheckpointCaptureOptions,
        worktree: RootDirectory,
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory,
        store: RepositoryObjectStore,
        limits: TreeishResourceLimits,
        beforeStabilityValidation: (@Sendable () throws -> Void)? = nil
    ) throws -> GitWorkspaceCheckpoint {
        guard options.maximumEntries > 0,
              options.maximumObjects > 0,
              options.maximumOverlayBytes >= 0 else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
        let initialSnapshot = try repositorySnapshot(
            headDirectory: headDirectory,
            refsDirectory: refsDirectory
        )
        let index = try Repository.readWorkspaceCheckpointIndex(
            bytes: initialSnapshot.indexBytes,
            store: store
        )
        let checkpointHead: GitWorkspaceCheckpointHead
        if let reference = initialSnapshot.head.reference {
            checkpointHead = .attached(
                reference: reference,
                objectID: initialSnapshot.head.objectID
            )
        } else if let objectID = initialSnapshot.head.objectID {
            checkpointHead = .detached(objectID: objectID)
        } else {
            checkpointHead = .unborn(reference: nil)
        }
        let logicalIndex = try index.entries.map {
            try GitWorkspaceCheckpointIndexEntry(
                path: GitPath(bytes: $0.path),
                objectID: ObjectID(
                    algorithm: index.objectFormat,
                    bytes: $0.objectID
                ),
                mode: $0.mode,
                stage: $0.stage,
                assumeValid: $0.assumeValid,
                skipWorktree: $0.skipWorktree,
                intentToAdd: $0.intentToAdd
            )
        }.sorted(by: GitWorkspaceCheckpoint.indexOrdering)
        guard logicalIndex.count <= options.maximumEntries else {
            throw ZlibError.resourceLimitExceeded
        }
        let trackedPaths = Set(
            logicalIndex.filter { $0.stage == 0 }.map(\.path.bytes)
        )
        let rules = try WorkingTreeRules(
            worktree: worktree,
            commonDirectory: refsDirectory
        )
        let initialFilesystemEntries = try captureOverlayEntries(
            in: worktree,
            rules: rules,
            ignoredFiles: options.ignoredFiles,
            tracked: trackedPaths,
            options: options,
            limits: limits
        )
        try beforeStabilityValidation?()
        let finalSnapshot = try repositorySnapshot(
            headDirectory: headDirectory,
            refsDirectory: refsDirectory
        )
        let finalRules = try WorkingTreeRules(
            worktree: worktree,
            commonDirectory: refsDirectory
        )
        let finalFilesystemEntries = try captureOverlayEntries(
            in: worktree,
            rules: finalRules,
            ignoredFiles: options.ignoredFiles,
            tracked: trackedPaths,
            options: options,
            limits: limits
        )
        guard initialSnapshot == finalSnapshot,
              initialFilesystemEntries.map(\.inventory) ==
                finalFilesystemEntries.map(\.inventory) else {
            throw GitWorkspaceCheckpointError.changedDuringCapture
        }
        // Blob publication happens only after the bounded stability comparison.
        let filesystemEntries = try writeOverlayEntries(
            initialFilesystemEntries,
            store: store
        )
        let headPaths: Set<[UInt8]>
        if let objectID = initialSnapshot.head.objectID {
            headPaths = try Repository.workspaceCheckpointTrackedPaths(
                head: objectID,
                store: store
            )
        } else {
            headPaths = []
        }
        let allTrackedPaths = headPaths.union(
            logicalIndex.filter { $0.stage == 0 }.map(\.path.bytes)
        )
        let presentPaths = Set(filesystemEntries.compactMap { entry in
            entry.kind == .directory ? nil : entry.path.bytes
        })
        let deletedPaths = try allTrackedPaths.subtracting(presentPaths).map {
            try GitPath(bytes: $0)
        }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }

        var roots = Set<ObjectID>()
        switch checkpointHead {
        case .attached(_, let objectID):
            if let objectID { roots.insert(objectID) }
        case .detached(let objectID):
            roots.insert(objectID)
        case .unborn:
            break
        }
        for entry in logicalIndex where !GitWorkspaceCheckpoint.isNullObjectID(entry.objectID) {
            guard entry.mode != 0o160000 else {
                // A gitlink points at another repository. Importing its object
                // into this object database would be a false representation.
                throw TreeishError.unsupportedSubmoduleUpdate(
                    entry.path,
                    "workspace checkpoints do not capture gitlinks"
                )
            }
            roots.insert(entry.objectID)
        }
        for entry in filesystemEntries {
            if let objectID = entry.contentObjectID { roots.insert(objectID) }
        }
        let objectRoots = roots.sorted(by: GitWorkspaceCheckpoint.objectOrdering)
        let required = try objectClosure(
            roots: objectRoots,
            objectFormat: index.objectFormat,
            store: store,
            maximumObjects: options.maximumObjects
        )
        return try GitWorkspaceCheckpoint(
            objectFormat: index.objectFormat,
            head: checkpointHead,
            indexVersion: index.version,
            indexEntries: logicalIndex,
            overlayEntries: filesystemEntries,
            deletedPaths: deletedPaths,
            ignoredFiles: options.ignoredFiles,
            objectRoots: objectRoots,
            requiredObjectIDs: required,
            operationContinuation: .unavailable
        )
    }

    static func missingObjects(
        checkpoint: GitWorkspaceCheckpoint,
        store: RepositoryObjectStore
    ) throws -> [ObjectID] {
        try checkpoint.validate()
        guard checkpoint.objectFormat == store.objectFormat else {
            throw GitWorkspaceCheckpointError.objectFormatMismatch
        }
        return try checkpoint.requiredObjectIDs.filter { identifier in
            do {
                _ = try store.read(identifier: identifier.bytes)
                return false
            } catch GitObjectError.objectNotFound {
                return true
            }
        }
    }

    static func export(
        checkpoint: GitWorkspaceCheckpoint,
        options: GitWorkspaceCheckpointTransferOptions,
        store: RepositoryObjectStore,
        limits: TreeishResourceLimits
    ) throws -> [GitWorkspaceCheckpointObjectChunk] {
        try checkpoint.validate()
        try validateTransferOptions(options, limits: limits)
        guard checkpoint.objectFormat == store.objectFormat else {
            throw GitWorkspaceCheckpointError.objectFormatMismatch
        }
        guard checkpoint.requiredObjectIDs.count <= options.maximumObjects else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
        var transferBytes = 0
        var result: [GitWorkspaceCheckpointObjectChunk] = []
        for identifier in checkpoint.requiredObjectIDs {
            let object: GitObject
            do {
                object = try store.read(identifier: identifier.bytes)
            } catch GitObjectError.objectNotFound {
                throw GitWorkspaceCheckpointError.incompleteObject(identifier)
            }
            guard object.payload.count <= limits.maximumObjectBytes,
                  transferBytes <= options.maximumTransferBytes - object.payload.count else {
                throw ZlibError.resourceLimitExceeded
            }
            transferBytes += object.payload.count
            let type: GitObjectKind = switch object.type {
            case .blob: .blob
            case .tree: .tree
            case .commit: .commit
            case .tag: .tag
            }
            if object.payload.isEmpty {
                result.append(try GitWorkspaceCheckpointObjectChunk(
                    objectID: identifier,
                    objectType: type,
                    objectByteCount: 0,
                    byteOffset: 0,
                    bytes: []
                ))
                continue
            }
            var offset = 0
            while offset < object.payload.count {
                let end = min(
                    object.payload.count,
                    offset + options.maximumChunkBytes
                )
                result.append(try GitWorkspaceCheckpointObjectChunk(
                    objectID: identifier,
                    objectType: type,
                    objectByteCount: object.payload.count,
                    byteOffset: offset,
                    bytes: Array(object.payload[offset..<end])
                ))
                offset = end
            }
        }
        return result
    }

    static func importObjects(
        checkpoint: GitWorkspaceCheckpoint,
        chunks: [GitWorkspaceCheckpointObjectChunk],
        options: GitWorkspaceCheckpointTransferOptions,
        store: RepositoryObjectStore,
        commonDirectory: RootDirectory,
        limits: TreeishResourceLimits
    ) throws -> GitWorkspaceCheckpointImportResult {
        try checkpoint.validate()
        try validateTransferOptions(options, limits: limits)
        guard checkpoint.objectFormat == store.objectFormat else {
            throw GitWorkspaceCheckpointError.objectFormatMismatch
        }
        let allowed = Set(checkpoint.requiredObjectIDs)
        var grouped: [ObjectID: [GitWorkspaceCheckpointObjectChunk]] = [:]
        var transferBytes = 0
        for chunk in chunks {
            _ = try GitWorkspaceCheckpointObjectChunk(
                objectID: chunk.objectID,
                objectType: chunk.objectType,
                objectByteCount: chunk.objectByteCount,
                byteOffset: chunk.byteOffset,
                bytes: chunk.bytes,
                contentDigest: chunk.contentDigest
            )
            guard chunk.objectID.algorithm == checkpoint.objectFormat,
                  allowed.contains(chunk.objectID),
                  chunk.bytes.count <= options.maximumChunkBytes,
                  chunk.contentDigest == SHA256.hash(chunk.bytes),
                  transferBytes <= options.maximumTransferBytes - chunk.bytes.count else {
                throw GitWorkspaceCheckpointError.invalidChunk
            }
            transferBytes += chunk.bytes.count
            grouped[chunk.objectID, default: []].append(chunk)
        }
        var imported: [PackObject] = []
        guard grouped.count <= options.maximumObjects else {
            throw GitWorkspaceCheckpointError.invalidChunk
        }
        for identifier in grouped.keys.sorted(by: GitWorkspaceCheckpoint.objectOrdering) {
            guard let values = grouped[identifier] else { continue }
            let chunks = values.sorted { $0.byteOffset < $1.byteOffset }
            guard let first = chunks.first,
                  chunks.allSatisfy({
                      $0.objectByteCount == first.objectByteCount &&
                      $0.objectType == first.objectType
                  }), first.objectByteCount <= limits.maximumObjectBytes,
                  (first.objectByteCount == 0
                      ? chunks.count == 1
                      : chunks.allSatisfy { !$0.bytes.isEmpty }) else {
                throw GitWorkspaceCheckpointError.invalidChunk
            }
            var payload: [UInt8] = []
            payload.reserveCapacity(first.objectByteCount)
            var expectedOffset = 0
            for chunk in chunks {
                guard chunk.byteOffset == expectedOffset else {
                    throw GitWorkspaceCheckpointError.invalidChunk
                }
                payload += chunk.bytes
                expectedOffset += chunk.bytes.count
            }
            guard payload.count == first.objectByteCount else {
                throw GitWorkspaceCheckpointError.incompleteObject(identifier)
            }
            let objectType: GitObjectType = switch first.objectType {
            case .blob: .blob
            case .tree: .tree
            case .commit: .commit
            case .tag: .tag
            }
            let object = GitObject(type: objectType, payload: payload)
            guard checkpoint.objectFormat.hash(object.canonicalBytes) == identifier.bytes else {
                throw GitWorkspaceCheckpointError.invalidChunk
            }
            imported.append(try PackObject(
                identifier: identifier.bytes,
                object: object
            ))
        }
        if !imported.isEmpty {
            try Repository.publishWorkspaceCheckpointPack(
                imported,
                objectFormat: checkpoint.objectFormat,
                in: commonDirectory
            )
        }
        let missing = try missingObjects(checkpoint: checkpoint, store: store)
        if missing.isEmpty {
            try validateObjectClosure(checkpoint: checkpoint, store: store)
        }
        let importedObjectIDs = try imported.map {
            try ObjectID(
                algorithm: checkpoint.objectFormat,
                bytes: $0.identifier
            )
        }
        return GitWorkspaceCheckpointImportResult(
            importedObjectIDs: importedObjectIDs,
            missingObjectIDs: missing
        )
    }

    static func materialize(
        checkpoint: GitWorkspaceCheckpoint,
        destination: GitPath,
        sourceRoot: TreeishRoot,
        sourceStore: RepositoryObjectStore,
        limits: TreeishResourceLimits,
        transferOptions: GitWorkspaceCheckpointTransferOptions
    ) async throws -> GitWorkspaceCheckpointMaterializationResult {
        try checkpoint.validate()
        if case .unborn = checkpoint.head {
            throw GitWorkspaceCheckpointError.unsupportedUnbornHead
        }
        guard !destination.bytes.isEmpty else {
            throw GitWorkspaceCheckpointError.unsafeDestination
        }
        try validateEmptyDestination(destination, in: sourceRoot.directory)
        try validateMaterializableOverlay(checkpoint: checkpoint, store: sourceStore)
        let chunks = try export(
            checkpoint: checkpoint,
            options: transferOptions,
            store: sourceStore,
            limits: limits
        )
        let target = try await Treeish.initialize(
            in: sourceRoot,
            at: destination,
            options: RepositoryInitialization(
                initialBranch: "checkpoint",
                objectFormat: checkpoint.objectFormat
            )
        )
        _ = try await target.importWorkspaceCheckpoint(
            checkpoint,
            chunks: chunks,
            options: transferOptions
        ).value()
        try await target.installWorkspaceCheckpoint(checkpoint).value()
        return GitWorkspaceCheckpointMaterializationResult(
            location: target.identity.location,
            operationContinuation: .unavailable
        )
    }

    static func installIntoCleanWorktree(
        checkpoint: GitWorkspaceCheckpoint,
        expectedGeneration: ObjectID,
        indexStore: GitIndexStore,
        worktree: RootDirectory,
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory,
        store: RepositoryObjectStore,
        limits: TreeishResourceLimits
    ) throws {
        try checkpoint.validate()
        if case .unborn = checkpoint.head {
            throw GitWorkspaceCheckpointError.unsupportedUnbornHead
        }
        guard checkpoint.objectFormat == store.objectFormat else {
            throw GitWorkspaceCheckpointError.objectFormatMismatch
        }
        let missing = try missingObjects(checkpoint: checkpoint, store: store)
        guard missing.isEmpty else {
            throw GitWorkspaceCheckpointError.incompleteObject(missing[0])
        }
        try validateObjectClosure(checkpoint: checkpoint, store: store)
        try validateMaterializableOverlay(checkpoint: checkpoint, store: store)
        _ = try Repository.validateWorkspaceCheckpointCleanDestination(
            expectedGeneration: expectedGeneration,
            ignoredFiles: checkpoint.ignoredFiles,
            indexStore: indexStore,
            worktree: worktree,
            headDirectory: headDirectory,
            refsDirectory: refsDirectory,
            store: store
        )
        let expectedCurrent = try capture(
            options: GitWorkspaceCheckpointCaptureOptions(
                ignoredFiles: checkpoint.ignoredFiles
            ),
            worktree: worktree,
            headDirectory: headDirectory,
            refsDirectory: refsDirectory,
            store: store,
            limits: limits
        )
        try replaceWorktree(
            expectedCurrent: expectedCurrent,
            replacement: checkpoint,
            indexStore: indexStore,
            worktree: worktree,
            headDirectory: headDirectory,
            refsDirectory: refsDirectory,
            store: store,
            limits: limits
        )
    }

    static func replaceWorktree(
        expectedCurrent: GitWorkspaceCheckpoint,
        replacement: GitWorkspaceCheckpoint,
        indexStore: GitIndexStore,
        worktree: RootDirectory,
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory,
        store: RepositoryObjectStore,
        limits: TreeishResourceLimits
    ) throws {
        try expectedCurrent.validate()
        try replacement.validate()
        guard expectedCurrent.objectFormat == store.objectFormat,
              replacement.objectFormat == store.objectFormat else {
            throw GitWorkspaceCheckpointError.objectFormatMismatch
        }
        guard expectedCurrent.ignoredFiles == replacement.ignoredFiles else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
        if case .unborn = replacement.head {
            throw GitWorkspaceCheckpointError.unsupportedUnbornHead
        }
        let missing = try missingObjects(checkpoint: replacement, store: store)
        guard missing.isEmpty else {
            throw GitWorkspaceCheckpointError.incompleteObject(missing[0])
        }
        try validateObjectClosure(checkpoint: replacement, store: store)
        try validateMaterializableOverlay(checkpoint: replacement, store: store)
        try Repository.ensureNoWorkspaceCheckpointOperation(in: headDirectory)
        let actual = try capture(
            options: GitWorkspaceCheckpointCaptureOptions(
                ignoredFiles: expectedCurrent.ignoredFiles
            ),
            worktree: worktree,
            headDirectory: headDirectory,
            refsDirectory: refsDirectory,
            store: store,
            limits: limits
        )
        guard actual == expectedCurrent else {
            throw GitWorkspaceCheckpointError.destinationIsActive
        }
        let currentPaths = Set(expectedCurrent.overlayEntries.compactMap {
            $0.kind == .directory ? nil : $0.path
        })
        let replacementPaths = Set(replacement.overlayEntries.compactMap {
            $0.kind == .directory ? nil : $0.path
        })
        if expectedCurrent.ignoredFiles == .exclude {
            let ignoredPaths = try ignoredFilesystemPaths(
                worktree: worktree,
                refsDirectory: refsDirectory
            )
            guard !ignoredPaths.contains(where: { ignored in
                replacementPaths.contains(where: { replacementPath in
                    pathsConflict(ignored, replacementPath)
                })
            }) else {
                throw GitWorkspaceCheckpointError.destinationIsActive
            }
        }
        let newHead = try linkedWorktreeHead(
            for: replacement,
            refsDirectory: refsDirectory
        )
        var transaction = try WorktreeTransaction.begin(
            paths: currentPaths.union(replacementPaths),
            gitDirectory: headDirectory,
            worktree: worktree,
            maximumBytes: limits.maximumTransactionBytes,
            publication: WorktreeTransaction.Publication(
                directory: .git,
                path: ["HEAD"],
                expected: Data(newHead)
            )
        )
        do {
            try removeCheckpointContents(expectedCurrent, from: worktree)
            try writeCheckpointContents(
                replacement,
                indexStore: indexStore,
                worktree: worktree,
                store: store
            )
            try verifyInstalledContents(
                replacement,
                indexStore: indexStore,
                worktree: worktree,
                refsDirectory: refsDirectory,
                store: store,
                limits: limits
            )
            try headDirectory.writeAtomically(newHead, to: ["HEAD"])
            guard try headDirectory.read(["HEAD"], limit: newHead.count) == newHead else {
                throw TreeishError.recoveryRequired(
                    "checkpoint replacement could not verify HEAD"
                )
            }
            try transaction.commit()
        } catch {
            try transaction.reconcileAfterFailure(commonDirectory: refsDirectory)
            throw error
        }
    }

    static func install(
        checkpoint: GitWorkspaceCheckpoint,
        indexStore: GitIndexStore,
        worktree: RootDirectory,
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory,
        store: RepositoryObjectStore
    ) throws {
        try checkpoint.validate()
        if case .unborn = checkpoint.head {
            throw GitWorkspaceCheckpointError.unsupportedUnbornHead
        }
        guard checkpoint.objectFormat == store.objectFormat else {
            throw GitWorkspaceCheckpointError.objectFormatMismatch
        }
        let missing = try missingObjects(checkpoint: checkpoint, store: store)
        guard missing.isEmpty else {
            throw GitWorkspaceCheckpointError.incompleteObject(missing[0])
        }
        try validateObjectClosure(checkpoint: checkpoint, store: store)
        try validateMaterializableOverlay(checkpoint: checkpoint, store: store)
        let files = checkpoint.overlayEntries.filter { $0.kind != .directory }
        guard files.allSatisfy({ entry in
            (try? worktree.exists(entry.path.components)) == false
        }) else {
            throw GitWorkspaceCheckpointError.destinationIsActive
        }
        try writeCheckpointContents(
            checkpoint,
            indexStore: indexStore,
            worktree: worktree,
            store: store
        )
        switch checkpoint.head {
        case .attached(let reference, let objectID):
            let head = Array("ref: \(reference.description)\n".utf8)
            try headDirectory.writeAtomically(head, to: ["HEAD"])
            if let objectID {
                try refsDirectory.writeAtomically(
                    Array("\(objectID.description)\n".utf8),
                    to: try referenceComponents(reference)
                )
            }
        case .detached(let objectID):
            try headDirectory.writeAtomically(
                Array("\(objectID.description)\n".utf8),
                to: ["HEAD"]
            )
        case .unborn:
            throw GitWorkspaceCheckpointError.unsupportedUnbornHead
        }
    }

    private static func linkedWorktreeHead(
        for checkpoint: GitWorkspaceCheckpoint,
        refsDirectory: RootDirectory
    ) throws -> [UInt8] {
        switch checkpoint.head {
        case .attached(let reference, let objectID):
            let actual = try Repository.workspaceCheckpointReferenceObject(
                reference,
                in: refsDirectory
            )
            guard actual == objectID else {
                throw GitWorkspaceCheckpointError.destinationGenerationMismatch(
                    expected: objectID,
                    actual: actual
                )
            }
            return Array("ref: \(reference.description)\n".utf8)
        case .detached(let objectID):
            return Array("\(objectID.description)\n".utf8)
        case .unborn:
            throw GitWorkspaceCheckpointError.unsupportedUnbornHead
        }
    }

    private static func removeCheckpointContents(
        _ checkpoint: GitWorkspaceCheckpoint,
        from worktree: RootDirectory
    ) throws {
        for entry in checkpoint.overlayEntries where entry.kind != .directory {
            let url = try worktree.url(
                for: entry.path.components,
                followFinalSymlink: false
            )
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let isSymbolicLink = (attributes?[.type] as? FileAttributeType)
                == .typeSymbolicLink
            if FileManager.default.fileExists(atPath: url.path)
                || isSymbolicLink {
                try FileManager.default.removeItem(at: url)
            }
        }
        let directories = checkpoint.overlayEntries
            .filter { $0.kind == .directory }
            .sorted {
                let leftDepth = $0.path.bytes.lazy.filter { $0 == 0x2f }.count
                let rightDepth = $1.path.bytes.lazy.filter { $0 == 0x2f }.count
                if leftDepth != rightDepth {
                    return leftDepth > rightDepth
                }
                return $1.path.bytes.lexicographicallyPrecedes($0.path.bytes)
            }
        for entry in directories {
            let url = try worktree.url(
                for: entry.path.components,
                followFinalSymlink: false
            )
            guard FileManager.default.fileExists(atPath: url.path),
                  try FileManager.default.contentsOfDirectory(atPath: url.path)
                    .isEmpty else {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func ignoredFilesystemPaths(
        worktree: RootDirectory,
        refsDirectory: RootDirectory
    ) throws -> [GitPath] {
        let rules = try WorkingTreeRules(
            worktree: worktree,
            commonDirectory: refsDirectory
        )
        let root = try worktree.url(for: [])
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }
        var result: [GitPath] = []
        while let value = enumerator.nextObject() as? URL {
            if value.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let path = try GitPath(
                worktree.relativeComponents(for: value).joined(separator: "/")
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: value.path
            )
            if attributes[.type] as? FileAttributeType != .typeDirectory,
               rules.isIgnored(path) {
                result.append(path)
            }
        }
        return result
    }

    private static func pathsConflict(_ left: GitPath, _ right: GitPath) -> Bool {
        left == right
            || left.bytes.starts(with: right.bytes + [0x2f])
            || right.bytes.starts(with: left.bytes + [0x2f])
    }

    private static func writeCheckpointContents(
        _ checkpoint: GitWorkspaceCheckpoint,
        indexStore: GitIndexStore,
        worktree: RootDirectory,
        store: RepositoryObjectStore
    ) throws {
        for entry in checkpoint.overlayEntries where entry.kind == .directory {
            try worktree.createDirectory(entry.path.components)
        }
        for entry in checkpoint.overlayEntries where entry.kind != .directory {
            guard let identifier = entry.contentObjectID else {
                throw GitWorkspaceCheckpointError.invalidManifest
            }
            let payload = try store.read(identifier: identifier.bytes).payload
            let url = try worktree.url(
                for: entry.path.components,
                followFinalSymlink: false
            )
            switch entry.kind {
            case .regularFile:
                try worktree.writeAtomically(payload, to: entry.path.components)
                try FileManager.default.setAttributes(
                    [.posixPermissions: entry.mode == 0o100755 ? 0o755 : 0o644],
                    ofItemAtPath: url.path
                )
            case .symbolicLink:
                guard let target = String(bytes: payload, encoding: .utf8) else {
                    throw TreeishError.pathEncodingUnsupported
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    atPath: url.path,
                    withDestinationPath: target
                )
            case .directory:
                throw GitWorkspaceCheckpointError.invalidManifest
            }
        }
        try indexStore.write(try checkpointIndex(checkpoint))
    }

    private static func checkpointIndex(
        _ checkpoint: GitWorkspaceCheckpoint
    ) throws -> GitIndex {
        let entries = try checkpoint.indexEntries.map { entry in
            try GitIndexEntry(
                path: entry.path.bytes,
                objectID: entry.objectID.bytes,
                mode: entry.mode,
                size: 0,
                modificationSeconds: 0,
                modificationNanoseconds: 0,
                stage: entry.stage,
                assumeValid: entry.assumeValid,
                skipWorktree: entry.skipWorktree,
                intentToAdd: entry.intentToAdd
            )
        }
        let needsExtendedFlags = entries.contains {
            $0.skipWorktree || $0.intentToAdd
        }
        return GitIndex(
            version: needsExtendedFlags
                ? max(checkpoint.indexVersion, 3)
                : checkpoint.indexVersion,
            objectFormat: checkpoint.objectFormat,
            entries: entries
        )
    }

    private static func verifyInstalledContents(
        _ checkpoint: GitWorkspaceCheckpoint,
        indexStore: GitIndexStore,
        worktree: RootDirectory,
        refsDirectory: RootDirectory,
        store: RepositoryObjectStore,
        limits: TreeishResourceLimits
    ) throws {
        let expectedIndex = try checkpointIndex(checkpoint)
        guard try indexStore.read() == expectedIndex else {
            throw TreeishError.recoveryRequired(
                "checkpoint installation could not verify its index"
            )
        }
        let expected = try checkpoint.overlayEntries.map { entry in
            let payload = try entry.contentObjectID.map {
                try store.read(identifier: $0.bytes).payload
            }
            return WorkspaceCheckpointOverlayInventoryEntry(
                path: entry.path,
                kind: entry.kind,
                origin: entry.origin,
                mode: entry.mode,
                contentByteCount: payload?.count ?? 0,
                contentDigest: payload.map { SHA256.hash($0) }
            )
        }.sorted {
            $0.path.bytes.lexicographicallyPrecedes($1.path.bytes)
        }
        let rules = try WorkingTreeRules(
            worktree: worktree,
            commonDirectory: refsDirectory
        )
        let actual = try captureOverlayEntries(
            in: worktree,
            rules: rules,
            ignoredFiles: checkpoint.ignoredFiles,
            tracked: Set(checkpoint.indexEntries.filter {
                $0.stage == 0
            }.map(\.path.bytes)),
            options: GitWorkspaceCheckpointCaptureOptions(
                maximumEntries: 1_000_000,
                maximumObjects: 1,
                maximumOverlayBytes: Int.max
            ),
            limits: limits
        ).map(\.inventory)
        guard actual == expected else {
            throw TreeishError.recoveryRequired(
                "checkpoint installation could not verify its worktree"
            )
        }
    }

    /// Takes one bounded repository identity sample. The surrounding capture
    /// compares two samples instead of retrying or publishing a torn snapshot.
    private static func repositorySnapshot(
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory
    ) throws -> WorkspaceCheckpointRepositorySnapshot {
        let leadingHead = try headIdentity(
            headDirectory: headDirectory,
            refsDirectory: refsDirectory
        )
        let indexBytes = try optionalFile(
            in: headDirectory,
            components: ["index"],
            limit: 512 * 1024 * 1024
        )
        let trailingHead = try headIdentity(
            headDirectory: headDirectory,
            refsDirectory: refsDirectory
        )
        guard leadingHead == trailingHead else {
            throw GitWorkspaceCheckpointError.changedDuringCapture
        }
        return WorkspaceCheckpointRepositorySnapshot(
            head: trailingHead,
            indexBytes: indexBytes
        )
    }

    private static func headIdentity(
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory
    ) throws -> WorkspaceCheckpointHeadIdentity {
        let head = try Repository.readWorkspaceCheckpointHead(
            headDirectory: headDirectory,
            refsDirectory: refsDirectory
        )
        return WorkspaceCheckpointHeadIdentity(
            reference: head.reference,
            objectID: head.objectID,
            bytes: try optionalFile(
                in: headDirectory,
                components: ["HEAD"],
                limit: 4096
            )
        )
    }

    private static func optionalFile(
        in directory: RootDirectory,
        components: [String],
        limit: Int
    ) throws -> [UInt8]? {
        do {
            return try directory.read(components, limit: limit)
        } catch RootDirectoryError.notFound {
            return nil
        }
    }

    private static func captureOverlayEntries(
        in worktree: RootDirectory,
        rules: WorkingTreeRules,
        ignoredFiles: GitWorkspaceCheckpointIgnoredFiles,
        tracked: Set<[UInt8]>,
        options: GitWorkspaceCheckpointCaptureOptions,
        limits: TreeishResourceLimits
    ) throws -> [WorkspaceCheckpointOverlayCaptureEntry] {
        let root = try worktree.url(for: [])
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            return []
        }
        var overlayBytes = 0
        var result: [WorkspaceCheckpointOverlayCaptureEntry] = []
        while let value = enumerator.nextObject() as? URL {
            if value.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard result.count < options.maximumEntries else {
                throw ZlibError.resourceLimitExceeded
            }
            let path = try GitPath(
                worktree.relativeComponents(for: value).joined(separator: "/")
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: value.path
            )
            let type = attributes[.type] as? FileAttributeType
            let ignored = rules.isIgnored(path)
            let origin: GitWorkspaceCheckpointOverlayOrigin
            if tracked.contains(path.bytes) {
                origin = .tracked
            } else if ignored {
                origin = .ignored
            } else {
                origin = .untracked
            }
            let hasTrackedDescendant = type == .typeDirectory && tracked.contains {
                $0.starts(with: path.bytes + [0x2f])
            }
            if ignored && origin != .tracked && ignoredFiles == .exclude &&
                !hasTrackedDescendant {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            if type == .typeDirectory {
                result.append(WorkspaceCheckpointOverlayCaptureEntry(
                    inventory: WorkspaceCheckpointOverlayInventoryEntry(
                        path: path,
                        kind: .directory,
                        origin: origin,
                        mode: 0o040000,
                        contentByteCount: 0,
                        contentDigest: nil
                    ),
                    payload: nil
                ))
                continue
            }
            guard type == .typeRegular || type == .typeSymbolicLink else {
                throw TreeishError.worktreeCollision(path)
            }
            let payload = try Repository.readWorkspaceCheckpointPayload(url: value)
            guard payload.count <= limits.maximumObjectBytes,
                  overlayBytes <= options.maximumOverlayBytes - payload.count else {
                throw ZlibError.resourceLimitExceeded
            }
            overlayBytes += payload.count
            let permissions = (attributes[.posixPermissions] as? NSNumber)?
                .uint16Value ?? 0o644
            let kind: GitWorkspaceCheckpointOverlayKind = type == .typeSymbolicLink
                ? .symbolicLink
                : .regularFile
            let mode: UInt32 = type == .typeSymbolicLink
                ? 0o120000
                : (permissions & 0o111 == 0 ? 0o100644 : 0o100755)
            result.append(WorkspaceCheckpointOverlayCaptureEntry(
                inventory: WorkspaceCheckpointOverlayInventoryEntry(
                    path: path,
                    kind: kind,
                    origin: origin,
                    mode: mode,
                    contentByteCount: payload.count,
                    contentDigest: SHA256.hash(payload)
                ),
                payload: payload
            ))
        }
        return result.sorted {
            $0.inventory.path.bytes.lexicographicallyPrecedes(
                $1.inventory.path.bytes
            )
        }
    }

    private static func writeOverlayEntries(
        _ captures: [WorkspaceCheckpointOverlayCaptureEntry],
        store: RepositoryObjectStore
    ) throws -> [GitWorkspaceCheckpointOverlayEntry] {
        try captures.map { capture in
            let inventory = capture.inventory
            let contentObjectID: ObjectID?
            if let payload = capture.payload {
                contentObjectID = try ObjectID(
                    algorithm: store.objectFormat,
                    bytes: store.write(GitObject(type: .blob, payload: payload))
                )
            } else {
                contentObjectID = nil
            }
            return try GitWorkspaceCheckpointOverlayEntry(
                path: inventory.path,
                kind: inventory.kind,
                origin: inventory.origin,
                mode: inventory.mode,
                contentObjectID: contentObjectID
            )
        }
    }

    private static func objectClosure(
        roots: [ObjectID],
        objectFormat: ObjectHashAlgorithm,
        store: RepositoryObjectStore,
        maximumObjects: Int
    ) throws -> [ObjectID] {
        var pending = roots.map { ($0, Optional<GitObjectType>.none) }
        var visited: Set<ObjectID> = []
        while let (identifier, expectedType) = pending.popLast() {
            guard !visited.contains(identifier) else { continue }
            guard visited.count < maximumObjects else {
                throw ZlibError.resourceLimitExceeded
            }
            visited.insert(identifier)
            let object = try store.read(identifier: identifier.bytes)
            guard expectedType == nil || object.type == expectedType else {
                throw GitObjectError.invalidHeader
            }
            for edge in try objectEdges(
                object,
                identifier: identifier,
                objectFormat: objectFormat
            ) {
                pending.append(edge)
            }
        }
        return visited.sorted(by: GitWorkspaceCheckpoint.objectOrdering)
    }

    private static func objectEdges(
        _ object: GitObject,
        identifier: ObjectID,
        objectFormat: ObjectHashAlgorithm
    ) throws -> [(ObjectID, GitObjectType?)] {
        switch object.type {
        case .blob:
            return []
        case .commit:
            let record = try CommitRecord(
                identifier: identifier.bytes,
                object: object
            )
            return try [(ObjectID(
                algorithm: objectFormat,
                bytes: record.tree
            ), .tree)] + record.parents.map {
                (try ObjectID(algorithm: objectFormat, bytes: $0), .commit)
            }
        case .tree:
            var cursor = 0
            var entries: [GitTreeEntry] = []
            var edges: [(ObjectID, GitObjectType?)] = []
            while cursor < object.payload.count {
                guard let space = object.payload[cursor...].firstIndex(of: 0x20),
                      space > cursor,
                      let nul = object.payload[space...].firstIndex(of: 0),
                      nul > space + 1,
                      let mode = GitFileMode(rawValue: String(
                          decoding: object.payload[cursor..<space],
                          as: UTF8.self
                      )),
                      nul + 1 + objectFormat.byteCount <= object.payload.count else {
                    throw GitObjectError.invalidHeader
                }
                let name = Array(object.payload[(space + 1)..<nul])
                guard name != Array(".git".utf8),
                      (try? GitPath(bytes: name)) != nil else {
                    throw GitObjectError.invalidHeader
                }
                let child = Array(object.payload[
                    (nul + 1)..<(nul + 1 + objectFormat.byteCount)
                ])
                let entry = try GitTreeEntry(
                    mode: mode,
                    name: name,
                    objectID: child
                )
                entries.append(entry)
                switch mode {
                case .tree:
                    edges.append((try ObjectID(
                        algorithm: objectFormat,
                        bytes: child
                    ), .tree))
                case .regular, .executable, .symbolicLink:
                    edges.append((try ObjectID(
                        algorithm: objectFormat,
                        bytes: child
                    ), .blob))
                case .gitlink:
                    break
                }
                cursor = nul + 1 + objectFormat.byteCount
            }
            guard GitObjectEncoder.tree(entries: entries).payload == object.payload else {
                throw GitObjectError.invalidHeader
            }
            return edges
        case .tag:
            guard let separator = object.payload.firstRange(
                of: Array("\n\n".utf8)
            ) else {
                throw GitObjectError.invalidHeader
            }
            var target: ObjectID?
            var expected: GitObjectType?
            for line in object.payload[..<separator.lowerBound].split(separator: 0x0a) {
                if line.starts(with: Array("object ".utf8)) {
                    guard target == nil else { throw GitObjectError.invalidHeader }
                    target = try ObjectID(
                        hex: String(decoding: line.dropFirst(7), as: UTF8.self),
                        algorithm: objectFormat
                    )
                } else if line.starts(with: Array("type ".utf8)) {
                    guard expected == nil,
                          let type = GitObjectType(rawValue: String(
                              decoding: line.dropFirst(5),
                              as: UTF8.self
                          )) else {
                        throw GitObjectError.invalidHeader
                    }
                    expected = type
                }
            }
            guard let target, let expected else {
                throw GitObjectError.invalidHeader
            }
            return [(target, expected)]
        }
    }

    private static func validateObjectClosure(
        checkpoint: GitWorkspaceCheckpoint,
        store: RepositoryObjectStore
    ) throws {
        let actual = try objectClosure(
            roots: checkpoint.objectRoots,
            objectFormat: checkpoint.objectFormat,
            store: store,
            maximumObjects: checkpoint.requiredObjectIDs.count + 1
        )
        guard actual == checkpoint.requiredObjectIDs else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
        let headObject: ObjectID? = switch checkpoint.head {
        case .attached(_, let objectID): objectID
        case .detached(let objectID): objectID
        case .unborn: nil
        }
        if let headObject {
            guard try store.read(identifier: headObject.bytes).type == .commit else {
                throw GitObjectError.invalidHeader
            }
        }
        for entry in checkpoint.overlayEntries {
            guard let identifier = entry.contentObjectID else { continue }
            guard try store.read(identifier: identifier.bytes).type == .blob else {
                throw GitObjectError.invalidHeader
            }
        }
        for entry in checkpoint.indexEntries
        where !GitWorkspaceCheckpoint.isNullObjectID(entry.objectID) {
            guard entry.mode != 0o160000,
                  try store.read(identifier: entry.objectID.bytes).type == .blob else {
                throw GitObjectError.invalidHeader
            }
        }
    }

    private static func validateMaterializableOverlay(
        checkpoint: GitWorkspaceCheckpoint,
        store: RepositoryObjectStore
    ) throws {
        for entry in checkpoint.overlayEntries {
            _ = try entry.path.components
            guard entry.path.bytes != Array(".git".utf8),
                  !entry.path.bytes.starts(with: Array(".git/".utf8)) else {
                throw GitWorkspaceCheckpointError.unsafeDestination
            }
            if entry.kind == .symbolicLink,
               let identifier = entry.contentObjectID {
                let payload = try store.read(identifier: identifier.bytes).payload
                guard String(bytes: payload, encoding: .utf8) != nil else {
                    throw TreeishError.pathEncodingUnsupported
                }
            }
        }
        for entry in checkpoint.indexEntries {
            _ = try entry.path.components
            guard entry.path.bytes != Array(".git".utf8),
                  !entry.path.bytes.starts(with: Array(".git/".utf8)) else {
                throw GitWorkspaceCheckpointError.unsafeDestination
            }
        }
    }

    private static func validateEmptyDestination(
        _ destination: GitPath,
        in root: RootDirectory
    ) throws {
        let components = try destination.components
        guard try root.exists(components) else {
            throw GitWorkspaceCheckpointError.unsafeDestination
        }
        let url = try root.url(for: components, followFinalSymlink: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              url.resolvingSymlinksInPath() == url else {
            throw GitWorkspaceCheckpointError.unsafeDestination
        }
        guard try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).isEmpty else {
            throw GitWorkspaceCheckpointError.destinationIsActive
        }
    }

    private static func validateTransferOptions(
        _ options: GitWorkspaceCheckpointTransferOptions,
        limits: TreeishResourceLimits
    ) throws {
        guard options.maximumChunkBytes > 0,
              options.maximumChunkBytes <= limits.maximumObjectBytes,
              options.maximumObjects > 0,
              options.maximumTransferBytes >= 0,
              options.maximumTransferBytes <= limits.maximumPackBytes else {
            throw GitWorkspaceCheckpointError.invalidManifest
        }
    }

    private static func referenceComponents(_ reference: RefName) throws -> [String] {
        guard let value = String(bytes: reference.bytes, encoding: .utf8) else {
            throw TreeishError.pathEncodingUnsupported
        }
        return value.split(separator: "/").map(String.init)
    }
}
