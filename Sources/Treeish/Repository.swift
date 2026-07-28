import Foundation
import TreeishCore
import TreeishDiff
import TreeishFileSystem
import TreeishGraph
import TreeishHTTP
import TreeishIndex
import TreeishObjects
import TreeishPacks
import TreeishProtocol

public actor Repository {
    public nonisolated let identity: RepositoryIdentity

    private let root: TreeishRoot
    private let gitDirectory: RootDirectory
    private let commonDirectory: RootDirectory
    private let objectStore: RepositoryObjectStore
    private let indexStore: GitIndexStore
    private let worktree: RootDirectory?
    private let repositoryCapabilities: RepositoryCapabilities
    private let resourceLimits: TreeishResourceLimits

    internal init(
        root: TreeishRoot,
        location: RepositoryLocation,
        options: RepositoryOpenOptions
    ) throws {
        self.root = root
        identity = RepositoryIdentity(root: root.identity, location: location)
        gitDirectory = try root.directory.childDirectory(
            location.gitDirectoryPath.components
        )
        commonDirectory = try root.directory.childDirectory(
            location.commonDirectoryPath.components
        )
        let capabilities = try Repository.inspectCapabilities(
            root: root,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory
        )
        repositoryCapabilities = capabilities
        let replacementObjects = try Repository.replacementObjects(
            directory: commonDirectory,
            objectFormat: capabilities.objectFormat
        )
        objectStore = try RepositoryObjectStore(
            directory: commonDirectory,
            grantedRoot: root.directory,
            objectFormat: capabilities.objectFormat,
            limits: options.resourceLimits,
            replacementObjects: replacementObjects
        )
        resourceLimits = options.resourceLimits
        indexStore = GitIndexStore(
            gitDirectory: gitDirectory,
            objectFormat: capabilities.objectFormat
        )
        if let worktreePath = location.worktreePath {
            worktree = try root.directory.childDirectory(worktreePath.components)
        } else {
            worktree = nil
        }
        if let worktree {
            try WorktreeTransaction.recover(
                gitDirectory: gitDirectory,
                commonDirectory: commonDirectory,
                worktree: worktree,
                maximumBytes: options.resourceLimits.maximumTransactionBytes
            )
        }
    }

    public func capabilities() -> RepositoryCapabilities {
        let capabilities = repositoryCapabilities
        let promisorRemotes = (try? GitConfiguration.load(
            from: commonDirectory
        )).map(Repository.promisorRemoteNames)
            ?? capabilities.promisorRemotes
        return RepositoryCapabilities(
            access: capabilities.access,
            objectFormat: capabilities.objectFormat,
            refStorage: capabilities.refStorage,
            isShallow: (try? commonDirectory.exists(["shallow"]))
                ?? capabilities.isShallow,
            usesAlternates: (try? commonDirectory.exists([
                "objects", "info", "alternates",
            ])) ?? capabilities.usesAlternates,
            hasMultiPackIndex: (
                try? commonDirectory.exists([
                    "objects", "pack", "multi-pack-index",
                ]) || commonDirectory.exists([
                    "objects", "pack", "multi-pack-index.d",
                    "multi-pack-index-chain",
                ])
            ) ?? capabilities.hasMultiPackIndex,
            promisorRemotes: promisorRemotes,
            index: capabilities.index,
            repositoryExtensions: capabilities.repositoryExtensions,
            operations: capabilities.operations,
            restrictions: capabilities.restrictions
        )
    }

    public func snapshot() async throws -> RepositorySnapshot {
        let head = try readHead()
        return RepositorySnapshot(
            headReference: head.reference,
            headObjectID: head.objectID,
            capabilities: capabilities()
        )
    }

    public func writeObject(
        type: GitObjectKind,
        payload: [UInt8]
    ) -> GitOperation<ObjectID> {
        let store = objectStore
        let access = repositoryCapabilities.access
        return GitOperation(phase: .compression) {
            try Task.checkCancellation()
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(
                    access.reason ?? .rootIsReadOnly
                )
            }
            let bytes = try store.write(
                GitObject(type: type.storageType, payload: payload)
            )
            return try ObjectID(bytes: bytes)
        }
    }

    public func readObject(
        _ identifier: ObjectID,
        services: RepositoryServices = .init()
    ) -> GitOperation<StoredObject> {
        let store = objectStore
        let common = commonDirectory
        let promisorRemotes = repositoryCapabilities.promisorRemotes
        return GitOperation(phase: .validating) {
            try Task.checkCancellation()
            guard identifier.algorithm == store.objectFormat else {
                throw TreeishError.unsupportedRepositoryFormat(
                    identifier.algorithm.rawValue
                )
            }
            let object = try await Repository.readPromisedObject(
                identifier.bytes,
                preferredRemotes: promisorRemotes,
                services: services,
                store: store,
                directory: common
            )
            return StoredObject(
                type: GitObjectKind(storageType: object.type),
                payload: object.payload
            )
        }
    }

    public func stage(_ request: StageRequest) -> GitOperation<IndexUpdate> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let commonDirectory = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .updatingIndex) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(
                    access.reason ?? .rootIsReadOnly
                )
            }
            guard let worktree else {
                throw TreeishError.repositoryNotFound
            }
            let rules = try WorkingTreeRules(
                worktree: worktree,
                commonDirectory: commonDirectory
            )
            var index = try indexStore.read()
            let existing = Dictionary(
                uniqueKeysWithValues: index.entries
                    .filter { $0.stage == 0 }
                    .map { ($0.path, $0) }
            )
            let requested = try Repository.expandPathspecs(
                request.pathspecs,
                in: worktree,
                tracked: index.entries.map(\.path)
            )
            var updated: [GitPath] = []
            var removed: [GitPath] = []
            for path in requested {
                try Task.checkCancellation()
                if existing[path.bytes]?.skipWorktree == true,
                   !request.includeSparsePaths {
                    throw TreeishError.pathOutsideSparseCheckout(path)
                }
                if rules.isIgnored(path), !request.forceIgnored {
                    throw TreeishError.ignoredPath(path)
                }
                let components = try path.components
                let url = try worktree.url(
                    for: components,
                    followFinalSymlink: false
                )
                guard try worktree.exists(components) else {
                    index.entries.removeAll { $0.path == path.bytes }
                    removed.append(path)
                    continue
                }
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: url.path
                )
                let type = attributes[.type] as? FileAttributeType
                guard type != .typeDirectory else { continue }
                let payload: [UInt8]
                let mode: UInt32
                if type == .typeSymbolicLink {
                    payload = Array(
                        try FileManager.default.destinationOfSymbolicLink(
                            atPath: url.path
                        ).utf8
                    )
                    mode = 0o120000
                } else {
                    payload = Array(try Data(contentsOf: url))
                    let permissions = (attributes[.posixPermissions] as? NSNumber)?
                        .uint16Value ?? 0o644
                    mode = permissions & 0o111 == 0 ? 0o100644 : 0o100755
                }
                let cleaned = try rules.clean(payload, path: path)
                let identifier = try store.write(
                    GitObject(type: .blob, payload: cleaned)
                )
                let date = attributes[.modificationDate] as? Date
                let interval = date?.timeIntervalSince1970 ?? 0
                let seconds = UInt32(max(0, min(interval, Double(UInt32.max))))
                let nanoseconds = UInt32(
                    max(0, min((interval - floor(interval)) * 1_000_000_000, Double(UInt32.max)))
                )
                let entry = try GitIndexEntry(
                    path: path.bytes,
                    objectID: identifier,
                    mode: mode,
                    size: UInt32(min(payload.count, Int(UInt32.max))),
                    modificationSeconds: seconds,
                    modificationNanoseconds: nanoseconds
                )
                index.entries.removeAll { $0.path == path.bytes }
                index.entries.append(entry)
                updated.append(path)
            }
            index = GitIndex(
                version: index.version,
                objectFormat: index.objectFormat,
                entries: index.entries
            )
            try indexStore.write(index)
            return IndexUpdate(addedOrUpdated: updated, removed: removed)
        }
    }

    public func status(
        _ options: StatusOptions = .init()
    ) -> GitOperation<Status> {
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let store = objectStore
        let root = root
        let worktreePath = identity.location.worktreePath
        return GitOperation(phase: .indexing) {
            guard let worktree else {
                return Status(entries: [])
            }
            let index = try indexStore.read()
            let rules = try WorkingTreeRules(
                worktree: worktree,
                commonDirectory: refsDirectory
            )
            let stageZero = Dictionary(uniqueKeysWithValues: index.entries
                .filter { $0.stage == 0 }
                .map { ($0.path, $0) })
            let conflicted = Set(index.entries.filter { $0.stage != 0 }.map(\.path))

            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            let headEntries: [[UInt8]: FlatTreeEntry]
            if let identifier = head.objectID {
                let commit = try store.read(identifier: identifier.bytes)
                let record = try CommitRecord(
                    identifier: identifier.bytes,
                    object: commit
                )
                headEntries = Dictionary(uniqueKeysWithValues:
                    try Repository.flattenTree(
                        identifier: record.tree,
                        prefix: [],
                        store: store
                    ).map { ($0.path, $0) }
                )
            } else {
                headEntries = [:]
            }

            var changes: [[UInt8]: (
                index: StatusChangeKind?,
                worktree: StatusChangeKind?
            )] = [:]
            for bytes in Set(headEntries.keys).union(stageZero.keys) {
                if conflicted.contains(bytes) {
                    changes[bytes] = (.unmerged, .unmerged)
                    continue
                }
                switch (headEntries[bytes], stageZero[bytes]) {
                case (nil, .some):
                    changes[bytes, default: (nil, nil)].index = .added
                case (.some, nil):
                    changes[bytes, default: (nil, nil)].index = .deleted
                case (.some(let headEntry), .some(let indexEntry)):
                    if headEntry.mode != indexEntry.mode {
                        changes[bytes, default: (nil, nil)].index = .typeChanged
                    } else if headEntry.objectID != indexEntry.objectID {
                        changes[bytes, default: (nil, nil)].index = .modified
                    }
                case (nil, nil):
                    break
                }
            }
            for bytes in conflicted {
                changes[bytes] = (.unmerged, .unmerged)
            }

            for (bytes, entry) in stageZero where !conflicted.contains(bytes) {
                let path = try GitPath(bytes: bytes)
                let url = try worktree.url(
                    for: path.components,
                    followFinalSymlink: false
                )
                guard try worktree.exists(path.components) else {
                    if entry.skipWorktree {
                        continue
                    }
                    changes[bytes, default: (nil, nil)].worktree = .deleted
                    continue
                }
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: url.path
                )
                let fileType = attributes[.type] as? FileAttributeType
                if entry.mode == 0o160000, fileType == .typeDirectory {
                    if let worktreePath {
                        let fullPath = try Repository.join(
                            worktreePath,
                            path
                        )
                        let location = try await Treeish.discover(
                            in: root,
                            from: fullPath
                        )
                        if location.worktreePath == fullPath {
                            let nested = try await Treeish.open(
                                location,
                                roots: [root]
                            )
                            let expected = try ObjectID(
                                algorithm: index.objectFormat,
                                bytes: entry.objectID
                            )
                            let nestedSnapshot = try await nested.snapshot()
                            let nestedStatus = await nested.status()
                            let nestedIsClean = try await nestedStatus
                                .value().isClean
                            if nestedSnapshot.headObjectID != expected ||
                                !nestedIsClean {
                                changes[
                                    bytes,
                                    default: (nil, nil)
                                ].worktree = .modified
                            }
                        }
                    }
                    continue
                }
                let isSymbolicLink = fileType == .typeSymbolicLink
                if fileType == .typeDirectory {
                    changes[bytes, default: (nil, nil)].worktree = .typeChanged
                    continue
                }
                let payload = try Repository.worktreePayload(url: url)
                let data = isSymbolicLink
                    ? payload
                    : try rules.clean(payload, path: path)
                let canonical = Array("blob \(data.count)\0".utf8) + data
                let permissions = (attributes[.posixPermissions] as? NSNumber)?
                    .uint16Value ?? 0o644
                let mode: UInt32 = isSymbolicLink
                    ? 0o120000
                    : (permissions & 0o111 == 0 ? 0o100644 : 0o100755)
                if mode != entry.mode {
                    changes[bytes, default: (nil, nil)].worktree = .typeChanged
                } else if store.objectFormat.hash(canonical) != entry.objectID {
                    changes[bytes, default: (nil, nil)].worktree = .modified
                }
            }
            if options.includeUntracked || options.includeIgnored {
                let all = try Repository.enumerateFiles(in: worktree)
                let gitlinkPrefixes = stageZero.values
                    .filter { $0.mode == 0o160000 }
                    .map { $0.path + [0x2f] }
                for path in all where stageZero[path.bytes] == nil {
                    if gitlinkPrefixes.contains(where: {
                        path.bytes.starts(with: $0)
                    }) {
                        continue
                    }
                    let ignored = rules.isIgnored(path)
                    if ignored, options.includeIgnored {
                        changes[path.bytes, default: (nil, nil)].worktree = .ignored
                    } else if !ignored, options.includeUntracked {
                        changes[path.bytes, default: (nil, nil)].worktree = .untracked
                    }
                }
            }
            return Status(
                entries: try changes.compactMap { bytes, value in
                    guard value.index != nil || value.worktree != nil else {
                        return nil
                    }
                    return StatusEntry(
                        path: try GitPath(bytes: bytes),
                        indexChange: value.index,
                        worktreeChange: value.worktree
                    )
                }.sorted {
                    $0.path.bytes.lexicographicallyPrecedes($1.path.bytes)
                }
            )
        }
    }

    public func submodules() -> GitOperation<[SubmoduleStatus]> {
        let root = root
        let worktree = worktree
        let worktreePath = identity.location.worktreePath
        let indexStore = indexStore
        let objectFormat = repositoryCapabilities.objectFormat
        return GitOperation(phase: .indexing) {
            guard let worktree, let worktreePath else {
                return []
            }
            let configurations = try Repository.submoduleConfigurations(
                worktree: worktree
            )
            let byPath = Dictionary(
                uniqueKeysWithValues: configurations.map {
                    ($0.path.bytes, $0)
                }
            )
            let index = try indexStore.read()
            let gitlinks = Dictionary(
                uniqueKeysWithValues: try index.entries
                    .filter { $0.stage == 0 && $0.mode == 0o160000 }
                    .map {
                        (
                            $0.path,
                            try ObjectID(
                                algorithm: objectFormat,
                                bytes: $0.objectID
                            )
                        )
                    }
            )
            var paths = Set(byPath.keys)
            paths.formUnion(gitlinks.keys)
            var result: [SubmoduleStatus] = []
            for bytes in paths.sorted(by: {
                $0.lexicographicallyPrecedes($1)
            }) {
                try Task.checkCancellation()
                let path = try GitPath(bytes: bytes)
                let configuration = byPath[bytes]
                let expected = gitlinks[bytes]
                guard configuration != nil else {
                    result.append(SubmoduleStatus(
                        configuration: nil,
                        path: path,
                        expectedCommit: expected,
                        checkedOutCommit: nil,
                        state: .unconfigured
                    ))
                    continue
                }
                guard expected != nil else {
                    result.append(SubmoduleStatus(
                        configuration: configuration,
                        path: path,
                        expectedCommit: nil,
                        checkedOutCommit: nil,
                        state: .missingGitlink
                    ))
                    continue
                }
                let fullPath = try Repository.join(
                    worktreePath,
                    path
                )
                guard try root.directory.exists(fullPath.components) else {
                    result.append(SubmoduleStatus(
                        configuration: configuration,
                        path: path,
                        expectedCommit: expected,
                        checkedOutCommit: nil,
                        state: .uninitialized
                    ))
                    continue
                }
                do {
                    let location = try await Treeish.discover(
                        in: root,
                        from: fullPath
                    )
                    guard location.worktreePath == fullPath else {
                        throw TreeishError.repositoryNotFound
                    }
                    let nested = try await Treeish.open(
                        location,
                        roots: [root]
                    )
                    let snapshot = try await nested.snapshot()
                    let checkedOut = snapshot.headObjectID
                    let dirty = try await nested.status().value().isClean == false
                    let state: SubmoduleState
                    if checkedOut != expected {
                        state = .differentCommit
                    } else if dirty {
                        state = .modified
                    } else {
                        state = .clean
                    }
                    result.append(SubmoduleStatus(
                        configuration: configuration,
                        path: path,
                        expectedCommit: expected,
                        checkedOutCommit: checkedOut,
                        state: state
                    ))
                } catch TreeishError.repositoryNotFound {
                    result.append(SubmoduleStatus(
                        configuration: configuration,
                        path: path,
                        expectedCommit: expected,
                        checkedOutCommit: nil,
                        state: .uninitialized
                    ))
                }
            }
            return result
        }
    }

    public func writeIndexTree() -> GitOperation<ObjectID> {
        let store = objectStore
        let indexStore = indexStore
        let access = repositoryCapabilities.access
        return GitOperation(phase: .compression) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(
                    access.reason ?? .rootIsReadOnly
                )
            }
            let index = try indexStore.read()
            guard index.entries.allSatisfy({ $0.stage == 0 }) else {
                throw GitIndexError.corrupt
            }
            let items = index.entries.map { entry in
                (
                    components: entry.path.split(separator: 0x2f).map(Array.init),
                    entry: entry
                )
            }
            let bytes = try Repository.writeTree(items: items, store: store)
            return try ObjectID(bytes: bytes)
        }
    }

    public func log(
        from starts: [ObjectID],
        limit: Int = 1_000
    ) -> GitOperation<[CommitInfo]> {
        let store = objectStore
        return GitOperation(phase: .counting) {
            guard limit > 0, limit <= 100_000,
                  starts.allSatisfy({
                      $0.algorithm == store.objectFormat
                  }) else {
                throw TreeishError.invalidObjectID
            }
            let graph = CommitGraph(source: RepositoryCommitSource(store: store))
            let records = try await graph.walk(from: starts.map(\.bytes))
            return try records.prefix(limit).map { record in
                CommitInfo(
                    objectID: try ObjectID(bytes: record.identifier),
                    tree: try ObjectID(bytes: record.tree),
                    parents: try record.parents.map {
                        try ObjectID(bytes: $0)
                    },
                    authorTime: record.authorTime,
                    message: record.message
                )
            }
        }
    }

    public func log(
        range: RevisionRange,
        limit: Int = 1_000
    ) -> GitOperation<[CommitInfo]> {
        let store = objectStore
        return GitOperation(phase: .counting) {
            guard limit > 0, limit <= 100_000,
                  range.left.algorithm == store.objectFormat,
                  range.right.algorithm == store.objectFormat else {
                throw TreeishError.invalidObjectID
            }
            let graph = CommitGraph(source: RepositoryCommitSource(store: store))
            let left = try await graph.walk(from: [range.left.bytes])
            let right = try await graph.walk(from: [range.right.bytes])
            let leftIDs = Set(left.map(\.identifier))
            let rightIDs = Set(right.map(\.identifier))
            let records: [CommitRecord]
            switch range.kind {
            case .exclusion:
                records = right.filter { !leftIDs.contains($0.identifier) }
            case .symmetricDifference:
                records = try await graph.walk(
                    from: [range.left.bytes, range.right.bytes]
                ).filter {
                    leftIDs.contains($0.identifier)
                        != rightIDs.contains($0.identifier)
                }
            }
            return try records.prefix(limit).map { record in
                CommitInfo(
                    objectID: try ObjectID(bytes: record.identifier),
                    tree: try ObjectID(bytes: record.tree),
                    parents: try record.parents.map {
                        try ObjectID(bytes: $0)
                    },
                    authorTime: record.authorTime,
                    message: record.message
                )
            }
        }
    }

    public func mergeBases(
        _ left: ObjectID,
        _ right: ObjectID
    ) -> GitOperation<[ObjectID]> {
        let store = objectStore
        return GitOperation(phase: .counting) {
            guard left.algorithm == store.objectFormat,
                  right.algorithm == store.objectFormat else {
                throw TreeishError.invalidObjectID
            }
            let graph = CommitGraph(source: RepositoryCommitSource(store: store))
            return try await graph.mergeBases(left.bytes, right.bytes).map {
                try ObjectID(bytes: $0)
            }
        }
    }

    public func diffBlobs(
        old: ObjectID,
        new: ObjectID
    ) -> GitOperation<BlobDiff> {
        let store = objectStore
        return GitOperation(phase: .counting) {
            let oldObject = try store.read(identifier: old.bytes)
            let newObject = try store.read(identifier: new.bytes)
            guard oldObject.type == .blob, newObject.type == .blob else {
                throw GitObjectError.invalidHeader
            }
            switch try DiffEngine.diff(old: oldObject.payload, new: newObject.payload) {
            case .identical: return .identical
            case .binary(let oldBytes, let newBytes):
                return .binary(oldBytes: oldBytes, newBytes: newBytes)
            case .text(let lines):
                return .text(lines.map { line in
                    switch line {
                    case .context(let bytes): .context(bytes)
                    case .deletion(let bytes): .deletion(bytes)
                    case .insertion(let bytes): .insertion(bytes)
                    }
                })
            }
        }
    }

    public func createLinkedWorktree(
        _ request: WorktreeRequest
    ) -> GitOperation<WorktreeResult> {
        let root = root
        let common = commonDirectory
        let store = objectStore
        let access = repositoryCapabilities.access
        return GitOperation(phase: .updatingWorktree) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            guard root.policy.allowsSiblingWorktrees,
                  request.start.algorithm == store.objectFormat else {
                throw TreeishError.invalidPath
            }
            let destinationComponents = try request.destination.components
            let destinationURL = try root.directory.url(
                for: destinationComponents,
                followFinalSymlink: false
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let contents = try FileManager.default.contentsOfDirectory(atPath: destinationURL.path)
                guard contents.isEmpty else { throw TreeishError.invalidPath }
            } else {
                try root.directory.createDirectory(destinationComponents)
            }
            let identifier = UUID().uuidString.lowercased()
            let administration = ["worktrees", identifier]
            try common.createDirectory(administration)
            let adminURL = try common.url(for: administration)
            let gitFileURL = destinationURL.appendingPathComponent(".git")
            let relativeAdmin = adminURL.path
            try root.directory.writeAtomically(
                Array("gitdir: \(relativeAdmin)\n".utf8),
                to: destinationComponents + [".git"]
            )
            try common.writeAtomically(
                Array("../..\n".utf8),
                to: administration + ["commondir"]
            )
            try common.writeAtomically(
                Array("\(gitFileURL.path)\n".utf8),
                to: administration + ["gitdir"]
            )
            let storage = try Repository.referenceStorage(directory: common)
            if storage.format == .reftable {
                let adminDirectory = try common.childDirectory(administration)
                try adminDirectory.createDirectory(["reftable"])
                try adminDirectory.createDirectory(["refs"])
                try adminDirectory.writeAtomically(
                    Array("ref: refs/heads/.invalid\n".utf8),
                    to: ["HEAD"]
                )
                try adminDirectory.writeAtomically(
                    Array("this repository uses the reftable format\n".utf8),
                    to: ["refs", "heads"]
                )
                var updates = [
                    ReftableUpdate(
                        name: try RefName("ORIG_HEAD"),
                        value: .direct(request.start, peeled: nil),
                        expected: .missing,
                        reflog: nil
                    ),
                ]
                if let branch = request.branch {
                    try Repository.publishReference(
                        directory: common,
                        name: branch,
                        value: request.start,
                        expected: nil,
                        requireMissing: true,
                        reflog: nil
                    )
                    updates.append(ReftableUpdate(
                        name: try RefName("HEAD"),
                        value: .symbolic(branch),
                        expected: .missing,
                        reflog: nil
                    ))
                } else {
                    updates.append(ReftableUpdate(
                        name: try RefName("HEAD"),
                        value: .direct(request.start, peeled: nil),
                        expected: .missing,
                        reflog: nil
                    ))
                }
                try ReftableStack(
                    directory: adminDirectory,
                    objectFormat: storage.objectFormat
                ).append(updates)
            } else {
                if let branch = request.branch {
                    try common.writeAtomically(
                        Array("\(request.start.description)\n".utf8),
                        to: try branch.pathComponents
                    )
                    try common.writeAtomically(
                        Array("ref: \(branch.description)\n".utf8),
                        to: administration + ["HEAD"]
                    )
                } else {
                    try common.writeAtomically(
                        Array("\(request.start.description)\n".utf8),
                        to: administration + ["HEAD"]
                    )
                }
            }
            let commit = try store.read(identifier: request.start.bytes)
            let record = try CommitRecord(identifier: request.start.bytes, object: commit)
            try Repository.materializeTree(
                identifier: record.tree,
                at: destinationComponents,
                root: root.directory,
                store: store
            )
            let flat = try Repository.flattenTree(identifier: record.tree, prefix: [], store: store)
            let adminDirectory = try common.childDirectory(administration)
            try GitIndexStore(
                gitDirectory: adminDirectory,
                objectFormat: store.objectFormat
            ).write(GitIndex(
                objectFormat: store.objectFormat,
                entries: try flat.map { try Repository.indexEntry($0, stage: 0, store: store) }
            ))
            return WorktreeResult(
                identifier: identifier,
                path: request.destination,
                head: request.start
            )
        }
    }

    public func listLinkedWorktrees() -> GitOperation<[LinkedWorktreeInfo]> {
        let root = root
        let common = commonDirectory
        return GitOperation(phase: .discovery) {
            try Repository.linkedWorktrees(root: root, common: common)
        }
    }

    public func lockLinkedWorktree(identifier: String, reason: String) -> GitOperation<Void> {
        let common = commonDirectory
        return GitOperation(phase: .updatingWorktree) {
            guard Repository.validWorktreeIdentifier(identifier),
                  !reason.contains("\n"), reason.utf8.count <= 4096,
                  try common.exists(["worktrees", identifier]) else {
                throw TreeishError.invalidPath
            }
            try common.writeAtomically(Array((reason + "\n").utf8), to: ["worktrees", identifier, "locked"])
        }
    }

    public func unlockLinkedWorktree(identifier: String) -> GitOperation<Void> {
        let common = commonDirectory
        return GitOperation(phase: .updatingWorktree) {
            guard Repository.validWorktreeIdentifier(identifier) else { throw TreeishError.invalidPath }
            let path = ["worktrees", identifier, "locked"]
            if try common.exists(path) { _ = try common.removeAtomically(path) }
        }
    }

    public func removeLinkedWorktree(
        identifier: String,
        force: Bool = false
    ) -> GitOperation<GitPath> {
        let root = root
        let common = commonDirectory
        let objectFormat = repositoryCapabilities.objectFormat
        return GitOperation(phase: .updatingWorktree) {
            guard Repository.validWorktreeIdentifier(identifier) else { throw TreeishError.invalidPath }
            let administration = ["worktrees", identifier]
            guard try common.exists(administration),
                  !(try common.exists(administration + ["locked"])) else {
                throw TreeishError.recoveryRequired("linked worktree is locked or missing")
            }
            let gitFileText = String(
                decoding: try common.read(administration + ["gitdir"], limit: 64 * 1024),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let destinationURL = URL(fileURLWithPath: gitFileText).deletingLastPathComponent()
            let components = try root.directory.relativeComponents(for: destinationURL)
            let path = try GitPath(components.joined(separator: "/"))
            if !force {
                let worktree = try RootDirectory(url: destinationURL)
                let admin = try common.childDirectory(administration)
                let index = try GitIndexStore(
                    gitDirectory: admin,
                    objectFormat: objectFormat
                ).read()
                guard try Repository.worktreeStatus(index: index, worktree: worktree).isEmpty,
                      Set(try Repository.enumerateFiles(in: worktree)).isSubset(
                        of: Set(index.entries.filter { $0.stage == 0 }.compactMap { try? GitPath(bytes: $0.path) })
                      ) else {
                    throw TreeishError.recoveryRequired("linked worktree has local changes")
                }
            }
            try FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.removeItem(at: try common.url(for: administration, followFinalSymlink: false))
            return path
        }
    }

    public func fetch(
        _ request: FetchRequest,
        services: RepositoryServices = .init()
    ) -> GitOperation<FetchResult> {
        let common = commonDirectory
        let headDirectory = gitDirectory
        let store = objectStore
        let access = repositoryCapabilities.access
        return GitOperation(phase: .negotiation) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            if let filter = request.filter {
                try Repository.configurePromisorRemote(
                    name: request.remoteName,
                    url: request.remote,
                    filter: filter,
                    directory: common
                )
            }
            let v2Capabilities: UploadPackV2Capabilities?
            let advertisement: UploadPackAdvertisement
            let credential: GitCredential?
            let client: SmartHTTPClient?
            let sshSession: (any SSHGitSession)?
            switch request.remote.transport {
            case .https:
                let url = request.remote.url
                credential = try await Repository.credential(
                    for: url,
                    services: services
                )
                let httpClient = SmartHTTPClient(
                    transport: services.httpTransport
                        ?? URLSessionSmartHTTPTransport()
                )
                client = httpClient
                sshSession = nil
                let advertisementResponse = try await httpClient.advertisement(
                    remote: url,
                    authorization: credential?.authorizationHeader,
                    protocolVersion: 2
                )
                var decoder = PacketLineDecoder()
                let packets = try decoder.append(advertisementResponse.body)
                try decoder.finish()
                let usesV2 = packets.contains {
                    if case .data(let bytes) = $0 {
                        return bytes == Array("version 2\n".utf8)
                            || bytes == Array("version 2".utf8)
                    }
                    return false
                }
                if usesV2 {
                    let capabilities = try UploadPackV2.parseCapabilities(
                        packets
                    )
                    v2Capabilities = capabilities
                    var prefixes = request.refspecs
                        .filter { !$0.negative }
                        .map(\.advertisementPrefix)
                    prefixes.append(Array("HEAD".utf8))
                    let refsResponse = try await httpClient.uploadPack(
                        remote: url,
                        body: try UploadPackV2.lsRefsRequest(
                            prefixes: prefixes,
                            objectFormat: store.objectFormat,
                            capabilities: capabilities
                        ),
                        authorization: credential?.authorizationHeader
                    )
                    var refsDecoder = PacketLineDecoder()
                    let refPackets = try refsDecoder.append(refsResponse.body)
                    try refsDecoder.finish()
                    advertisement = try UploadPackV2.parseLsRefs(refPackets)
                } else {
                    v2Capabilities = nil
                    advertisement = try UploadPackV0.parseAdvertisement(packets)
                }
            case .ssh:
                guard let endpoint = request.remote.sshEndpoint,
                      let transport = services.sshTransport
                else {
                    throw TreeishError.remoteTransportUnavailable(.ssh)
                }
                credential = nil
                client = nil
                let session = try await transport.open(
                    SSHGitSessionRequest(
                        endpoint: endpoint,
                        service: .uploadPack
                    )
                )
                sshSession = session
                var decoder = PacketLineDecoder()
                let packets = try decoder.append(
                    try await session.advertisement()
                )
                try decoder.finish()
                v2Capabilities = nil
                advertisement = try UploadPackV0.parseAdvertisement(packets)
            }
            let positiveRefspecs = request.refspecs.filter { !$0.negative }
            let negativeRefspecs = request.refspecs.filter(\.negative)
            let selected = advertisement.references.filter { value in
                positiveRefspecs.contains { $0.matches(value.name) }
                    && !negativeRefspecs.contains {
                        $0.matches(value.name)
                    }
            }
            if selected.isEmpty {
                guard !request.requiresMatch else {
                    throw TreeishError.referenceNotFound
                }
                let pruned = request.prune
                    ? try Repository.pruneFetchedReferences(
                        positive: positiveRefspecs,
                        negative: negativeRefspecs,
                        advertisement: advertisement,
                        directory: common
                    )
                    : []
                try headDirectory.writeAtomically([], to: ["FETCH_HEAD"])
                return FetchResult(
                    receivedObjects: 0,
                    updatedReferences: [],
                    remoteHead: nil,
                    shallowBoundaries: try Repository
                        .shallowIdentifiers(
                            directory: common,
                            objectFormat: store.objectFormat
                        )
                        .sorted {
                            $0.lexicographicallyPrecedes($1)
                        }
                        .map {
                            try ObjectID(
                                algorithm: store.objectFormat,
                                bytes: $0
                            )
                        },
                    prunedReferences: pruned
                )
            }
            let wants = Array(Set(selected.map(\.objectID)))
            let localReferences = try Repository.allReferences(directory: common)
            let haves = Array(Set(localReferences.values.map(\.bytes)))
            let existingShallow = try Repository.shallowIdentifiers(
                directory: common,
                objectFormat: store.objectFormat
            )
            let deepen: UInt32?
            let deepenSince: Int64?
            let deepenNot: [String]
            switch request.shallow {
            case .none:
                deepen = nil
                deepenSince = nil
                deepenNot = []
            case .depth(let depth):
                deepen = depth
                deepenSince = nil
                deepenNot = []
            case .since(let seconds):
                deepen = nil
                deepenSince = seconds
                deepenNot = []
            case .excluding(let revisions):
                deepen = nil
                deepenSince = nil
                deepenNot = revisions
            case .sinceExcluding(let seconds, let revisions):
                deepen = nil
                deepenSince = seconds
                deepenNot = revisions
            case .unshallow:
                deepen = UInt32(Int32.max)
                deepenSince = nil
                deepenNot = []
            }
            let body = if let v2Capabilities {
                try UploadPackV2.fetchRequest(
                    wants: wants,
                    haves: haves,
                    shallow: Array(existingShallow),
                    deepen: deepen,
                    deepenSince: deepenSince,
                    deepenNot: deepenNot,
                    filter: request.filter?.rawValue,
                    objectFormat: store.objectFormat,
                    capabilities: v2Capabilities
                )
            } else {
                try UploadPackV0.fetchRequest(
                    wants: wants,
                    haves: haves,
                    shallow: Array(existingShallow),
                    deepen: deepen,
                    deepenSince: deepenSince,
                    deepenNot: deepenNot,
                    filter: request.filter?.rawValue,
                    objectFormat: store.objectFormat,
                    capabilities: advertisement.capabilities
                )
            }
            let responseBody: [UInt8]
            if let sshSession {
                responseBody = try await sshSession.exchange(body)
            } else if let client {
                responseBody = try await client.uploadPack(
                    remote: request.remote.url,
                    body: body,
                    authorization: credential?.authorizationHeader
                ).body
            } else {
                throw TreeishError.remoteTransportUnavailable(
                    request.remote.transport
                )
            }
            let fetchResponse: UploadPackFetchResponse
            if v2Capabilities != nil {
                var fetchDecoder = PacketLineDecoder()
                let fetchPackets = try fetchDecoder.append(responseBody)
                try fetchDecoder.finish()
                fetchResponse = try UploadPackV2.parseFetchResponse(
                    fetchPackets
                )
            } else {
                fetchResponse = try UploadPackV0.parseFetchResponse(
                    responseBody
                )
            }
            let pack = try PackReader.read(
                fetchResponse.pack,
                objectFormat: store.objectFormat,
                externalBase: { identifier in
                    try? store.read(identifier: identifier)
                }
            )
            try Repository.publishPack(
                pack.objects,
                objectFormat: store.objectFormat,
                in: common,
                promisor: request.filter != nil
            )
            var shallow = existingShallow
            shallow.formUnion(fetchResponse.shallow)
            shallow.subtract(fetchResponse.unshallow)
            try Repository.publishShallowIdentifiers(
                shallow,
                directory: common,
                objectFormat: store.objectFormat
            )
            store.setShallowIdentifiers(shallow)
            var updates: [RefUpdateResult] = []
            var fetchHead: [UInt8] = []
            for value in selected {
                let current = try ObjectID(bytes: value.objectID)
                var destinations: [RefName: Bool] = [:]
                for refspec in positiveRefspecs
                where refspec.matches(value.name) {
                    if let target = try refspec.localReference(
                        for: value.name
                    ) {
                        destinations[target] =
                            (destinations[target] ?? false) || refspec.force
                    }
                }
                for (target, force) in destinations {
                    let prior = try? Repository.readReference(
                        directory: common,
                        name: target
                    )
                    if !force, let prior, prior != current {
                        if target.description.hasPrefix("refs/tags/") {
                            throw TreeishError.referenceChanged
                        }
                        let graph = CommitGraph(
                            source: RepositoryCommitSource(store: store)
                        )
                        guard try await graph.isAncestor(
                            prior.bytes,
                            of: current.bytes
                        ) else {
                            throw TreeishError.referenceChanged
                        }
                    }
                    try Repository.publishReference(
                        directory: common,
                        name: target,
                        value: current,
                        expected: prior,
                        requireMissing: prior == nil,
                        reflog: nil
                    )
                    updates.append(
                        RefUpdateResult(
                            name: target,
                            previous: prior,
                            current: current
                        )
                    )
                }
                let headPrefix = Array("refs/heads/".utf8)
                let tagPrefix = Array("refs/tags/".utf8)
                let description: String
                if value.name.starts(with: headPrefix) {
                    let branch = String(
                        decoding: value.name.dropFirst(headPrefix.count),
                        as: UTF8.self
                    )
                    description = "branch '\(branch)'"
                } else if value.name.starts(with: tagPrefix) {
                    let tag = String(
                        decoding: value.name.dropFirst(tagPrefix.count),
                        as: UTF8.self
                    )
                    description = "tag '\(tag)'"
                } else {
                    let reference = String(
                        decoding: value.name,
                        as: UTF8.self
                    )
                    description = "'\(reference)'"
                }
                fetchHead += Array(
                    "\(current.description)\t\t\(description) of \(request.remote.description)\n".utf8
                )
            }
            var pruned: [RefName] = []
            if request.prune {
                pruned = try Repository.pruneFetchedReferences(
                    positive: positiveRefspecs,
                    negative: negativeRefspecs,
                    advertisement: advertisement,
                    directory: common
                )
            }
            try headDirectory.writeAtomically(fetchHead, to: ["FETCH_HEAD"])
            let remoteHead = try advertisement.symbolicHead.flatMap { symbolic -> RefName? in
                let bytes = Array(symbolic.utf8)
                return try positiveRefspecs.lazy.compactMap {
                    try $0.localReference(for: bytes)
                }.first
            }
            return FetchResult(
                receivedObjects: pack.objects.count,
                updatedReferences: updates,
                remoteHead: remoteHead,
                shallowBoundaries: try shallow.sorted {
                    $0.lexicographicallyPrecedes($1)
                }.map {
                    try ObjectID(
                        algorithm: store.objectFormat,
                        bytes: $0
                    )
                },
                prunedReferences: pruned.sorted {
                    $0.bytes.lexicographicallyPrecedes($1.bytes)
                }
            )
        }
    }

    public func push(
        _ request: PushRequest,
        services: RepositoryServices = .init()
    ) -> GitOperation<PushResult> {
        let store = objectStore
        let access = repositoryCapabilities.access
        let localDirectory = commonDirectory
        return GitOperation(phase: .negotiation) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let credential: GitCredential?
            let client: SmartHTTPClient?
            let sshSession: (any SSHGitSession)?
            let advertisementBytes: [UInt8]
            switch request.remote.transport {
            case .https:
                let url = request.remote.url
                credential = try await Repository.credential(
                    for: url,
                    services: services
                )
                let httpClient = SmartHTTPClient(
                    transport: services.httpTransport
                        ?? URLSessionSmartHTTPTransport()
                )
                client = httpClient
                sshSession = nil
                advertisementBytes = try await httpClient
                    .receiveAdvertisement(
                        remote: url,
                        authorization: credential?.authorizationHeader
                    ).body
            case .ssh:
                guard let endpoint = request.remote.sshEndpoint,
                      let transport = services.sshTransport
                else {
                    throw TreeishError.remoteTransportUnavailable(.ssh)
                }
                credential = nil
                client = nil
                let session = try await transport.open(
                    SSHGitSessionRequest(
                        endpoint: endpoint,
                        service: .receivePack
                    )
                )
                sshSession = session
                advertisementBytes = try await session.advertisement()
            }
            var decoder = PacketLineDecoder()
            let packets = try decoder.append(advertisementBytes)
            try decoder.finish()
            let advertisement = try UploadPackV0.parseAdvertisement(packets)
            if request.requiresAtomic,
               !advertisement.capabilities.contains("atomic") {
                throw TreeishError.unsupportedRepositoryFormat("remote does not support atomic push")
            }
            if !request.options.isEmpty,
               !advertisement.capabilities.contains("push-options") {
                throw TreeishError.unsupportedRepositoryFormat(
                    "remote does not support push options"
                )
            }
            var commands: [ReceivePackCommand] = []
            var desired: [RefName: ObjectID?] = [:]
            var objectsByID: [[UInt8]: PackObject] = [:]
            let remoteObjects = Set(advertisement.references.map(\.objectID))
            for refspec in request.refspecs {
                let advertised = advertisement.references.first {
                    $0.name == refspec.destination.bytes
                }
                let oldBytes = advertised?.objectID ?? [UInt8](
                    repeating: 0,
                    count: store.objectFormat.byteCount
                )
                let newValue = try refspec.source.map {
                    try Repository.readReference(directory: localDirectory, name: $0)
                }
                if newValue == nil,
                   !advertisement.capabilities.contains("delete-refs") {
                    throw TreeishError.unsupportedRepositoryFormat(
                        "remote does not support deleting references"
                    )
                }
                if !refspec.force, let old = advertised?.objectID, let newValue {
                    let graph = CommitGraph(source: RepositoryCommitSource(store: store))
                    guard try await graph.isAncestor(old, of: newValue.bytes) else {
                        throw TreeishError.referenceChanged
                    }
                }
                if let newValue {
                    for object in try Repository.reachablePackObjects(
                        from: newValue.bytes,
                        excluding: remoteObjects,
                        store: store
                    ) {
                        objectsByID[object.identifier] = object
                    }
                }
                desired[refspec.destination] = newValue
                commands.append(try ReceivePackCommand(
                    old: oldBytes,
                    new: newValue?.bytes ?? [UInt8](
                        repeating: 0,
                        count: store.objectFormat.byteCount
                    ),
                    name: refspec.destination.bytes
                ))
            }
            let pack: [UInt8]
            if request.refspecs.contains(where: { $0.source != nil }) {
                pack = try PackWriter.write(
                    objectsByID.values.sorted {
                        $0.identifier.lexicographicallyPrecedes(
                            $1.identifier
                        )
                    },
                    objectFormat: store.objectFormat
                ).pack
            } else {
                pack = []
            }
            let body = try ReceivePackV0.request(
                commands: commands,
                pack: pack,
                requiresAtomic: request.requiresAtomic,
                pushOptions: request.options,
                objectFormat: store.objectFormat,
                advertisedCapabilities: advertisement.capabilities
            )
            let resultBody: [UInt8]
            do {
                if let sshSession {
                    resultBody = try await sshSession.exchange(body)
                } else if let client {
                    resultBody = try await client.receivePack(
                        remote: request.remote.url,
                        body: body,
                        authorization: credential?.authorizationHeader
                    ).body
                } else {
                    throw TreeishError.remoteTransportUnavailable(
                        request.remote.transport
                    )
                }
            } catch {
                let reconciliation = PushReconciliation(expectedReferences: desired)
                let encoded = (try? JSONEncoder().encode(reconciliation))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                throw TreeishError.indeterminateRemoteResult(
                    "receive-pack outcome unknown; reconcile by fetching refs: \(encoded)"
                )
            }
            let usesSideband = advertisement.capabilities.contains("side-band-64k")
            let hasStatus = advertisement.capabilities.contains(
                "report-status-v2"
            ) || advertisement.capabilities.contains("report-status")
            let result: ReceivePackResult
            do {
                result = try ReceivePackV0.parseResponse(
                    resultBody,
                    sideband: usesSideband,
                    requiresStatus: hasStatus,
                    expectedReferences: request.refspecs.map {
                        $0.destination.bytes
                    }
                )
            } catch let ReceivePackError.unpackFailed(reason) {
                throw ReceivePackError.unpackFailed(reason)
            } catch {
                let reconciliation = PushReconciliation(
                    expectedReferences: desired
                )
                let encoded = (try? JSONEncoder().encode(reconciliation))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                throw TreeishError.indeterminateRemoteResult(
                    "receive-pack status invalid; reconcile by fetching refs: \(encoded)"
                )
            }
            var references: [PushRefResult] = []
            for refspec in request.refspecs {
                guard let status = result.statuses.first(where: { value in
                    switch value {
                    case .accepted(let name): return name == refspec.destination.bytes
                    case .rejected(let name, _): return name == refspec.destination.bytes
                    }
                }) else { throw ReceivePackError.malformedStatus }
                let advertised = advertisement.references.first {
                    $0.name == refspec.destination.bytes
                }
                let previous = try advertised.map {
                    try ObjectID(bytes: $0.objectID)
                }
                let disposition: PushRefDisposition
                switch status {
                case .accepted: disposition = .accepted
                case .rejected(_, let reason): disposition = .rejected(reason: reason)
                }
                references.append(PushRefResult(
                    reference: refspec.destination,
                    previous: previous,
                    current: desired[refspec.destination] ?? nil,
                    disposition: disposition
                ))
            }
            return PushResult(
                references: references,
                atomic: request.refspecs.count <= 1 || request.requiresAtomic
            )
        }
    }

    public func checkout(
        _ request: CheckoutRequest,
        services: RepositoryServices = .init()
    ) -> GitOperation<CheckoutResult> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let promisorRemotes = repositoryCapabilities.promisorRemotes
        let limits = resourceLimits
        let access = repositoryCapabilities.access
        let refStorage = repositoryCapabilities.refStorage
        return GitOperation(phase: .updatingWorktree) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            guard let worktree,
                  request.commit.algorithm == store.objectFormat else {
                throw TreeishError.repositoryNotFound
            }
            let commitObject = try await Repository.readPromisedObject(
                request.commit.bytes,
                preferredRemotes: promisorRemotes,
                services: services,
                store: store,
                directory: refsDirectory
            )
            let commit = try CommitRecord(identifier: request.commit.bytes, object: commitObject)
            let target = try await Repository.flattenPromisedTree(
                identifier: commit.tree,
                prefix: [],
                preferredRemotes: promisorRemotes,
                services: services,
                store: store,
                directory: refsDirectory
            )
            let sparse = try SparseCheckoutRules(
                gitDirectory: headDirectory,
                commonDirectory: refsDirectory
            )
            let workingTreeRules = try WorkingTreeRules(
                worktree: worktree,
                commonDirectory: refsDirectory
            )
            let includedTarget = try target.filter {
                sparse.includes(try GitPath(bytes: $0.path))
            }
            for entry in includedTarget where entry.mode != 0o160000 {
                _ = try await Repository.readPromisedObject(
                    entry.objectID,
                    preferredRemotes: promisorRemotes,
                    services: services,
                    store: store,
                    directory: refsDirectory
                )
            }
            let currentIndex = try indexStore.read()
            let tracked = Set(currentIndex.entries.filter { $0.stage == 0 }.map(\.path))
            let targetPaths = Set(includedTarget.map(\.path))
            for entry in target where !tracked.contains(entry.path) {
                let path = try GitPath(bytes: entry.path)
                if try worktree.exists(path.components) {
                    throw TreeishError.worktreeCollision(path)
                }
            }
            for entry in currentIndex.entries where entry.stage == 0 {
                let path = try GitPath(bytes: entry.path)
                guard try worktree.exists(path.components) else {
                    continue
                }
                let url = try worktree.url(for: path.components, followFinalSymlink: false)
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: url.path
                )
                if entry.mode == 0o160000,
                   attributes[.type] as? FileAttributeType == .typeDirectory {
                    continue
                }
                let bytes = try Repository.worktreePayload(url: url)
                let cleaned = entry.mode == 0o120000
                    ? bytes
                    : try workingTreeRules.clean(bytes, path: path)
                let canonical =
                    Array("blob \(cleaned.count)\0".utf8) + cleaned
                guard store.objectFormat.hash(canonical) == entry.objectID else {
                    throw TreeishError.worktreeCollision(path)
                }
            }
            let affected = try Set(tracked.union(targetPaths).map(GitPath.init(bytes:)))
            let expectedPublication = Data("\(request.commit.description)\n".utf8)
            var transaction = try WorktreeTransaction.begin(
                paths: affected,
                gitDirectory: headDirectory,
                worktree: worktree,
                maximumBytes: limits.maximumTransactionBytes,
                publication: WorktreeTransaction.Publication(
                    directory: request.reference == nil ? .git : .common,
                    path: request.reference?.pathComponents ?? ["HEAD"],
                    expected: expectedPublication,
                    kind: refStorage == .reftable
                        ? .reference
                        : .file
                )
            )
            do {
                for pathBytes in tracked.subtracting(targetPaths) {
                    let path = try GitPath(bytes: pathBytes)
                    let url = try worktree.url(for: path.components, followFinalSymlink: false)
                    if try worktree.exists(path.components) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
                for entry in includedTarget {
                    try Repository.materializeFlatEntry(
                        entry,
                        worktree: worktree,
                        store: store,
                        rules: workingTreeRules
                    )
                }
                let entries = try target.map { value -> GitIndexEntry in
                    let size: UInt32
                    let path = try GitPath(bytes: value.path)
                    let included = sparse.includes(path)
                    if value.mode == 0o160000 || !included {
                        size = 0
                    } else {
                        let blob = try store.read(identifier: value.objectID)
                        size = UInt32(
                            min(blob.payload.count, Int(UInt32.max))
                        )
                    }
                    return try GitIndexEntry(
                        path: value.path,
                        objectID: value.objectID,
                        mode: value.mode,
                        size: size,
                        modificationSeconds: 0,
                        modificationNanoseconds: 0,
                        skipWorktree: !included
                    )
                }
                try indexStore.write(GitIndex(
                    version: sparse.enabled
                        ? max(currentIndex.version, 3)
                        : currentIndex.version,
                    objectFormat: currentIndex.objectFormat,
                    entries: entries
                ))
                if let reference = request.reference {
                    try Repository.publishCheckoutReferences(
                        headDirectory: headDirectory,
                        refsDirectory: refsDirectory,
                        reference: reference,
                        value: request.commit
                    )
                } else {
                    try Repository.publishDetachedHead(
                        headDirectory: headDirectory,
                        refsDirectory: refsDirectory,
                        value: request.commit
                    )
                }
                try transaction.commit()
                return CheckoutResult(
                    commit: request.commit,
                    reference: request.reference,
                    pathsWritten: includedTarget.count
                )
            } catch {
                try transaction.reconcileAfterFailure(
                    commonDirectory: refsDirectory
                )
                throw error
            }
        }
    }

    public func reset(_ request: ResetRequest) -> GitOperation<CheckoutResult> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let limits = resourceLimits
        let access = repositoryCapabilities.access
        let refStorage = repositoryCapabilities.refStorage
        return GitOperation(phase: .reconciling) {
            guard case .readWrite = access,
                  request.commit.algorithm == store.objectFormat else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let object = try store.read(identifier: request.commit.bytes)
            let commit = try CommitRecord(identifier: request.commit.bytes, object: object)
            let target = try Repository.flattenTree(identifier: commit.tree, prefix: [], store: store)
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            let currentIndex = try indexStore.read()
            func publishReference() throws {
                if let reference = head.reference {
                    try Repository.publishReference(
                        directory: refsDirectory,
                        name: reference,
                        value: request.commit,
                        expected: head.objectID,
                        requireMissing: head.objectID == nil,
                        reflog: nil
                    )
                } else {
                    try Repository.publishDetachedHead(
                        headDirectory: headDirectory,
                        refsDirectory: refsDirectory,
                        value: request.commit
                    )
                }
            }
            if request.mode == .mixed {
                let entries = try target.map { try Repository.indexEntry($0, stage: 0, store: store) }
                try indexStore.write(GitIndex(
                    version: currentIndex.version,
                    objectFormat: currentIndex.objectFormat,
                    entries: entries
                ))
            } else if request.mode == .hard {
                guard let worktree else { throw TreeishError.repositoryNotFound }
                let paths = try Set(
                    (currentIndex.entries.map(\.path) + target.map(\.path))
                        .map(GitPath.init(bytes:))
                )
                let expected = Data("\(request.commit.description)\n".utf8)
                var transaction = try WorktreeTransaction.begin(
                    paths: paths,
                    gitDirectory: headDirectory,
                    worktree: worktree,
                    maximumBytes: limits.maximumTransactionBytes,
                    publication: WorktreeTransaction.Publication(
                        directory: head.reference == nil ? .git : .common,
                        path: head.reference?.pathComponents ?? ["HEAD"],
                        expected: expected,
                        kind: refStorage == .reftable ? .reference : .file
                    )
                )
                do {
                    try Repository.replaceWorktree(
                        with: commit.tree,
                        indexStore: indexStore,
                        worktree: worktree,
                        store: store
                    )
                    try publishReference()
                    try transaction.commit()
                } catch {
                    try transaction.reconcileAfterFailure(
                        commonDirectory: refsDirectory
                    )
                    throw error
                }
                return CheckoutResult(
                    commit: request.commit,
                    reference: head.reference,
                    pathsWritten: target.count
                )
            }
            try publishReference()
            return CheckoutResult(
                commit: request.commit,
                reference: head.reference,
                pathsWritten: 0
            )
        }
    }

    public func restore(_ request: RestoreRequest) -> GitOperation<IndexUpdate> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let limits = resourceLimits
        let access = repositoryCapabilities.access
        return GitOperation(phase: .reconciling) {
            guard case .readWrite = access, request.restoreIndex || request.restoreWorktree,
                  let worktree else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let sourceID: ObjectID
            if let source = request.source { sourceID = source }
            else {
                guard let head = try Repository.readHead(
                    headDirectory: headDirectory,
                    refsDirectory: refsDirectory
                ).objectID else { throw TreeishError.referenceNotFound }
                sourceID = head
            }
            let commit = try CommitRecord(
                identifier: sourceID.bytes,
                object: store.read(identifier: sourceID.bytes)
            )
            let source = Dictionary(uniqueKeysWithValues: try Repository.flattenTree(
                identifier: commit.tree,
                prefix: [],
                store: store
            ).map { ($0.path, $0) })
            var index = try indexStore.read()
            let rules = try WorkingTreeRules(
                worktree: worktree,
                commonDirectory: refsDirectory
            )
            var candidateBytes = Set(source.keys)
            candidateBytes.formUnion(index.entries.map(\.path))
            let candidates = try candidateBytes.map(GitPath.init(bytes:))
            let selected = request.pathspecs.isEmpty
                ? candidateBytes
                : Set(GitPathspec.select(candidates, using: request.pathspecs).map(\.bytes))
            let affected = try Set(selected.map(GitPath.init(bytes:)))
            func apply() throws -> IndexUpdate {
                var updated: [GitPath] = []
                var removed: [GitPath] = []
                for pathBytes in selected.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let path = try GitPath(bytes: pathBytes)
                if request.restoreIndex {
                    index.entries.removeAll { $0.path == pathBytes }
                    if let value = source[pathBytes] {
                        index.entries.append(try Repository.indexEntry(value, stage: 0, store: store))
                        updated.append(path)
                    } else { removed.append(path) }
                }
                if request.restoreWorktree {
                    let url = try worktree.url(for: path.components, followFinalSymlink: false)
                    if let value = source[pathBytes] {
                        let object = try store.read(identifier: value.objectID)
                        if value.mode == 0o120000 {
                            if FileManager.default.fileExists(atPath: url.path) {
                                try FileManager.default.removeItem(at: url)
                            }
                            try FileManager.default.createSymbolicLink(
                                atPath: url.path,
                                withDestinationPath: String(decoding: object.payload, as: UTF8.self)
                            )
                        } else {
                            try worktree.writeAtomically(
                                rules.smudge(object.payload, path: path),
                                to: path.components
                            )
                            try FileManager.default.setAttributes(
                                [.posixPermissions: value.mode == 0o100755 ? 0o755 : 0o644],
                                ofItemAtPath: url.path
                            )
                        }
                    } else if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
                }
                if request.restoreIndex {
                    try indexStore.write(
                        GitIndex(
                            version: index.version,
                            objectFormat: index.objectFormat,
                            entries: index.entries
                        )
                    )
                }
                return IndexUpdate(addedOrUpdated: updated, removed: removed)
            }
            if request.restoreWorktree {
                return try WorktreeTransaction.perform(
                    paths: affected,
                    gitDirectory: headDirectory,
                    commonDirectory: refsDirectory,
                    worktree: worktree,
                    maximumBytes: limits.maximumTransactionBytes,
                    apply
                )
            }
            return try apply()
        }
    }

    public func applyPatch(
        _ request: ApplyPatchRequest
    ) -> GitOperation<ApplyPatchResult> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let gitDirectory = gitDirectory
        let commonDirectory = commonDirectory
        let limits = resourceLimits
        let access = repositoryCapabilities.access
        return GitOperation(phase: .updatingWorktree) {
            guard case .readWrite = access,
                  request.updateIndex || request.updateWorktree,
                  request.maximumOffsetSearch >= 0 else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            if request.updateWorktree, worktree == nil {
                throw TreeishError.repositoryNotFound
            }
            let patch = try UnifiedPatch(bytes: request.patch)
            var index = try indexStore.read()
            let rules: WorkingTreeRules?
            if let worktree {
                rules = try WorkingTreeRules(
                    worktree: worktree,
                    commonDirectory: commonDirectory
                )
            } else {
                rules = nil
            }
            let affected = try Set(patch.files.map {
                try GitPath(bytes: $0.newPath ?? $0.oldPath ?? [])
            })
            func apply() throws -> ApplyPatchResult {
                var updated: [GitPath] = []
                var deleted: [GitPath] = []
                for file in patch.files {
                try Task.checkCancellation()
                let pathBytes = file.newPath ?? file.oldPath ?? []
                let path = try GitPath(bytes: pathBytes)
                let existingEntry = index.entries.first {
                    $0.path == (file.oldPath ?? pathBytes) && $0.stage == 0
                }
                let original: [UInt8]
                if request.updateWorktree, let worktree,
                   try worktree.exists(path.components) {
                    let url = try worktree.url(
                        for: path.components,
                        followFinalSymlink: false
                    )
                    original = try Repository.worktreePayload(url: url)
                } else if let existingEntry {
                    original = try store.read(identifier: existingEntry.objectID).payload
                } else {
                    original = []
                }
                let result = try file.apply(
                    to: original,
                    maximumOffsetSearch: request.maximumOffsetSearch
                )
                if request.updateWorktree, let worktree {
                    if file.newPath == nil {
                        let url = try worktree.url(
                            for: path.components,
                            followFinalSymlink: false
                        )
                        if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                        }
                    } else {
                        try worktree.writeAtomically(result, to: path.components)
                    }
                }
                if request.updateIndex {
                    index.entries.removeAll {
                        $0.path == (file.oldPath ?? pathBytes)
                            || $0.path == pathBytes
                    }
                    if file.newPath != nil {
                        let cleaned = try rules?.clean(result, path: path) ?? result
                        let identifier = try store.write(
                            GitObject(type: .blob, payload: cleaned)
                        )
                        index.entries.append(
                            try GitIndexEntry(
                                path: pathBytes,
                                objectID: identifier,
                                mode: existingEntry?.mode ?? 0o100644,
                                size: UInt32(min(result.count, Int(UInt32.max))),
                                modificationSeconds: 0,
                                modificationNanoseconds: 0
                            )
                        )
                    }
                }
                if file.newPath == nil { deleted.append(path) }
                else { updated.append(path) }
                }
                if request.updateIndex {
                    try indexStore.write(
                        GitIndex(
                            version: index.version,
                            objectFormat: index.objectFormat,
                            entries: index.entries
                        )
                    )
                }
                return ApplyPatchResult(updated: updated, deleted: deleted)
            }
            if request.updateWorktree, let worktree {
                return try WorktreeTransaction.perform(
                    paths: affected,
                    gitDirectory: gitDirectory,
                    commonDirectory: commonDirectory,
                    worktree: worktree,
                    maximumBytes: limits.maximumTransactionBytes,
                    apply
                )
            }
            return try apply()
        }
    }

    public func createBundle(references: [RefName]) -> GitOperation<BundleArchive> {
        let store = objectStore
        let directory = commonDirectory
        return GitOperation(phase: .compression) {
            guard !references.isEmpty else { throw TreeishError.referenceNotFound }
            var resolved: [RefName: ObjectID] = [:]
            var objectsByID: [[UInt8]: PackObject] = [:]
            for reference in references {
                let identifier = try Repository.readDirectReference(
                    directory: directory,
                    components: reference.pathComponents
                )
                resolved[reference] = identifier
                for object in try Repository.reachablePackObjects(
                    from: identifier.bytes,
                    excluding: [],
                    store: store
                ) {
                    objectsByID[object.identifier] = object
                }
            }
            let archive = try PackWriter.write(
                objectsByID.values.sorted {
                    $0.identifier.lexicographicallyPrecedes($1.identifier)
                },
                objectFormat: store.objectFormat
            )
            var bytes = Array("# v2 git bundle\n".utf8)
            for reference in references.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
                guard let identifier = resolved[reference] else { continue }
                bytes += Array("\(identifier.description) \(reference.description)\n".utf8)
            }
            bytes.append(0x0a)
            bytes += archive.pack
            return BundleArchive(bytes: bytes, references: resolved)
        }
    }

    public func importBundle(_ bytes: [UInt8]) -> GitOperation<BundleImportResult> {
        let store = objectStore
        let common = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .quarantining) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            guard bytes.starts(with: Array("# v2 git bundle\n".utf8)),
                  let separator = bytes.firstRange(of: Array("\n\nPACK".utf8))
            else { throw TreeishError.unsupportedRepositoryFormat("bundle") }
            let header = bytes[..<separator.lowerBound].split(separator: 0x0a)
            var references: [RefName: ObjectID] = [:]
            for line in header.dropFirst() {
                if line.first == 0x2d {
                    let fields = line.dropFirst().split(separator: 0x20, maxSplits: 1)
                    guard let objectHex = fields.first else {
                        throw TreeishError.unsupportedRepositoryFormat("bundle prerequisite")
                    }
                    let prerequisite = try ObjectID(hex: String(decoding: objectHex, as: UTF8.self))
                    _ = try store.read(identifier: prerequisite.bytes)
                    continue
                }
                let fields = line.split(separator: 0x20, maxSplits: 1)
                guard fields.count == 2 else {
                    throw TreeishError.unsupportedRepositoryFormat("bundle header")
                }
                let identifier = try ObjectID(hex: String(decoding: fields[0], as: UTF8.self))
                let name = try RefName(validating: Array(fields[1]))
                references[name] = identifier
            }
            let packStart = separator.upperBound - 4
            let pack = try PackReader.read(
                Array(bytes[packStart...]),
                objectFormat: store.objectFormat,
                externalBase: { identifier in
                    try? store.read(identifier: identifier)
                }
            )
            try Repository.publishPack(
                pack.objects,
                objectFormat: store.objectFormat,
                in: common
            )
            for identifier in references.values {
                _ = try store.read(identifier: identifier.bytes)
            }
            return BundleImportResult(
                receivedObjects: pack.objects.count,
                references: references
            )
        }
    }

    public func merge(_ request: MergeRequest) -> GitOperation<MergeResult> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .reconciling) {
            guard case .readWrite = access, let worktree,
                  request.other.algorithm == store.objectFormat else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            guard let ours = head.objectID, let headReference = head.reference else {
                throw TreeishError.malformedReference
            }
            let currentIndex = try indexStore.read()
            let dirty = try Repository.worktreeStatus(
                index: currentIndex,
                worktree: worktree
            )
            guard dirty.isEmpty else {
                throw TreeishError.recoveryRequired("merge requires a clean worktree")
            }
            let graph = CommitGraph(source: RepositoryCommitSource(store: store))
            if try await graph.isAncestor(request.other.bytes, of: ours.bytes) {
                return .alreadyUpToDate(ours)
            }
            if try await graph.isAncestor(ours.bytes, of: request.other.bytes) {
                let otherRecord = try CommitRecord(
                    identifier: request.other.bytes,
                    object: store.read(identifier: request.other.bytes)
                )
                try Repository.replaceWorktree(
                    with: otherRecord.tree,
                    indexStore: indexStore,
                    worktree: worktree,
                    store: store
                )
                try Repository.publishReference(
                    directory: refsDirectory,
                    name: headReference,
                    value: request.other,
                    expected: ours,
                    requireMissing: false,
                    reflog: nil
                )
                return .fastForward(from: ours, to: request.other)
            }
            guard let baseID = try await graph.mergeBases(ours.bytes, request.other.bytes).first else {
                throw TreeishError.recoveryRequired("unrelated histories")
            }
            let baseRecord = try CommitRecord(
                identifier: baseID,
                object: store.read(identifier: baseID)
            )
            let oursRecord = try CommitRecord(
                identifier: ours.bytes,
                object: store.read(identifier: ours.bytes)
            )
            let theirsRecord = try CommitRecord(
                identifier: request.other.bytes,
                object: store.read(identifier: request.other.bytes)
            )
            let base = Dictionary(uniqueKeysWithValues: try Repository.flattenTree(
                identifier: baseRecord.tree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let oursTree = Dictionary(uniqueKeysWithValues: try Repository.flattenTree(
                identifier: oursRecord.tree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let theirsTree = Dictionary(uniqueKeysWithValues: try Repository.flattenTree(
                identifier: theirsRecord.tree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let mergePlan = try Repository.mergeTrees(
                base: base,
                ours: oursTree,
                theirs: theirsTree,
                worktree: worktree,
                store: store
            )
            let indexEntries = mergePlan.entries
            let conflicts = mergePlan.conflicts
            try indexStore.write(GitIndex(
                version: currentIndex.version,
                objectFormat: currentIndex.objectFormat,
                entries: indexEntries
            ))
            try headDirectory.writeAtomically(
                Array("\(ours.description)\n".utf8),
                to: ["ORIG_HEAD"]
            )
            try headDirectory.writeAtomically(
                Array("\(request.other.description)\n".utf8),
                to: ["MERGE_HEAD"]
            )
            try headDirectory.writeAtomically(request.message, to: ["MERGE_MSG"])
            if !conflicts.isEmpty { return .conflicted(conflicts) }
            let items = indexEntries.map {
                (components: $0.path.split(separator: 0x2f).map(Array.init), entry: $0)
            }
            let tree = try Repository.writeTree(items: items, store: store)
            try Repository.materializeTree(identifier: tree, at: [], root: worktree, store: store)
            let commitObject = GitObjectEncoder.commit(
                treeHex: try ObjectID(bytes: tree).description,
                parentHexes: [ours.description, request.other.description],
                author: request.author.storageSignature,
                committer: request.committer.storageSignature,
                message: request.message
            )
            let commitBytes = try store.write(commitObject)
            let commitID = try ObjectID(bytes: commitBytes)
            try Repository.publishReference(
                directory: refsDirectory,
                name: headReference,
                value: commitID,
                expected: ours,
                requireMissing: false,
                reflog: nil
            )
            try Repository.clearMergeState(in: headDirectory)
            return .merged(commitID)
        }
    }

    public func continueMerge(
        _ request: MergeContinuationRequest
    ) -> GitOperation<CommitResult> {
        let store = objectStore
        let indexStore = indexStore
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .updatingRefs) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let mergeHead = try ObjectID(hex: String(
                decoding: headDirectory.read(["MERGE_HEAD"], limit: 4096),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines))
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            guard let ours = head.objectID, let reference = head.reference else {
                throw TreeishError.malformedReference
            }
            let index = try indexStore.read()
            guard index.entries.allSatisfy({ $0.stage == 0 }) else {
                throw TreeishError.recoveryRequired("merge conflicts remain unresolved")
            }
            let items = index.entries.map {
                (components: $0.path.split(separator: 0x2f).map(Array.init), entry: $0)
            }
            let treeBytes = try Repository.writeTree(items: items, store: store)
            let tree = try ObjectID(bytes: treeBytes)
            let storedMessage = try headDirectory.read(["MERGE_MSG"], limit: 16 * 1024 * 1024)
            let commit = GitObjectEncoder.commit(
                treeHex: tree.description,
                parentHexes: [ours.description, mergeHead.description],
                author: request.author.storageSignature,
                committer: request.committer.storageSignature,
                message: request.message ?? storedMessage
            )
            let identifier = try ObjectID(bytes: store.write(commit))
            try Repository.publishReference(
                directory: refsDirectory,
                name: reference,
                value: identifier,
                expected: ours,
                requireMissing: false,
                reflog: ReflogMetadata(
                    signature: request.committer,
                    message: "commit (merge): merge"
                )
            )
            try Repository.clearMergeState(in: headDirectory)
            return CommitResult(objectID: identifier, updatedReference: reference)
        }
    }

    public func abortMerge() -> GitOperation<ObjectID> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .reconciling) {
            guard case .readWrite = access, let worktree else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let original = try ObjectID(hex: String(
                decoding: headDirectory.read(["ORIG_HEAD"], limit: 4096),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines))
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            guard let reference = head.reference else { throw TreeishError.malformedReference }
            let record = try CommitRecord(
                identifier: original.bytes,
                object: store.read(identifier: original.bytes)
            )
            try Repository.replaceWorktree(
                with: record.tree,
                indexStore: indexStore,
                worktree: worktree,
                store: store
            )
            try Repository.publishReference(
                directory: refsDirectory,
                name: reference,
                value: original,
                expected: head.objectID,
                requireMissing: false,
                reflog: nil
            )
            try Repository.clearMergeState(in: headDirectory)
            return original
        }
    }

    public func cherryPick(_ request: CherryPickRequest) -> GitOperation<CherryPickResult> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .reconciling) {
            guard case .readWrite = access, let worktree,
                  request.commit.algorithm == store.objectFormat else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            guard let ours = head.objectID, let reference = head.reference else {
                throw TreeishError.malformedReference
            }
            let currentIndex = try indexStore.read()
            guard try Repository.worktreeStatus(index: currentIndex, worktree: worktree).isEmpty else {
                throw TreeishError.recoveryRequired("cherry-pick requires a clean worktree")
            }
            let picked = try CommitRecord(
                identifier: request.commit.bytes,
                object: store.read(identifier: request.commit.bytes)
            )
            let oursRecord = try CommitRecord(
                identifier: ours.bytes,
                object: store.read(identifier: ours.bytes)
            )
            let baseTree: [UInt8]
            if let parent = picked.parents.first {
                baseTree = try CommitRecord(
                    identifier: parent,
                    object: store.read(identifier: parent)
                ).tree
            } else {
                baseTree = try store.write(GitObjectEncoder.tree(entries: []))
            }
            let base = Dictionary(uniqueKeysWithValues: try Repository.flattenTree(
                identifier: baseTree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let oursTree = Dictionary(uniqueKeysWithValues: try Repository.flattenTree(
                identifier: oursRecord.tree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let theirsTree = Dictionary(uniqueKeysWithValues: try Repository.flattenTree(
                identifier: picked.tree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let plan = try Repository.mergeTrees(
                base: base,
                ours: oursTree,
                theirs: theirsTree,
                worktree: worktree,
                store: store
            )
            let index = GitIndex(
                version: currentIndex.version,
                objectFormat: currentIndex.objectFormat,
                entries: plan.entries
            )
            try indexStore.write(index)
            try headDirectory.writeAtomically(Array("\(ours.description)\n".utf8), to: ["ORIG_HEAD"])
            try headDirectory.writeAtomically(
                Array("\(request.commit.description)\n".utf8),
                to: ["CHERRY_PICK_HEAD"]
            )
            let message = request.message ?? picked.message
            try headDirectory.writeAtomically(message, to: ["CHERRY_PICK_MSG"])
            if !plan.conflicts.isEmpty { return .conflicted(plan.conflicts) }
            let identifier = try Repository.commitSequencerIndex(
                index: index,
                parent: ours,
                reference: reference,
                author: request.author,
                committer: request.committer,
                message: message,
                store: store,
                refsDirectory: refsDirectory
            )
            try Repository.clearCherryPickState(in: headDirectory)
            return .committed(identifier)
        }
    }

    public func continueCherryPick(
        _ request: MergeContinuationRequest
    ) -> GitOperation<CommitResult> {
        let store = objectStore
        let indexStore = indexStore
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .updatingRefs) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            _ = try headDirectory.read(["CHERRY_PICK_HEAD"], limit: 4096)
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            guard let parent = head.objectID, let reference = head.reference else {
                throw TreeishError.malformedReference
            }
            let index = try indexStore.read()
            guard index.entries.allSatisfy({ $0.stage == 0 }) else {
                throw TreeishError.recoveryRequired("cherry-pick conflicts remain unresolved")
            }
            let stored = try headDirectory.read(["CHERRY_PICK_MSG"], limit: 16 * 1024 * 1024)
            let identifier = try Repository.commitSequencerIndex(
                index: index,
                parent: parent,
                reference: reference,
                author: request.author,
                committer: request.committer,
                message: request.message ?? stored,
                store: store,
                refsDirectory: refsDirectory
            )
            try Repository.clearCherryPickState(in: headDirectory)
            return CommitResult(objectID: identifier, updatedReference: reference)
        }
    }

    public func abortCherryPick() -> GitOperation<ObjectID> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        return GitOperation(phase: .reconciling) {
            guard let worktree else { throw TreeishError.repositoryNotFound }
            let original = try ObjectID(hex: String(
                decoding: headDirectory.read(["ORIG_HEAD"], limit: 4096),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines))
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            guard let reference = head.reference else { throw TreeishError.malformedReference }
            let record = try CommitRecord(
                identifier: original.bytes,
                object: store.read(identifier: original.bytes)
            )
            try Repository.replaceWorktree(
                with: record.tree,
                indexStore: indexStore,
                worktree: worktree,
                store: store
            )
            try Repository.publishReference(
                directory: refsDirectory,
                name: reference,
                value: original,
                expected: head.objectID,
                requireMissing: false,
                reflog: nil
            )
            try Repository.clearCherryPickState(in: headDirectory)
            return original
        }
    }

    public func rebase(_ request: RebaseRequest) -> GitOperation<RebaseResult> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .reconciling) {
            guard case .readWrite = access, let worktree,
                  request.onto.algorithm == store.objectFormat,
                  request.commits.allSatisfy({
                      $0.algorithm == store.objectFormat
                  }) else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            guard let original = head.objectID, let reference = head.reference else {
                throw TreeishError.malformedReference
            }
            guard try Repository.worktreeStatus(index: indexStore.read(), worktree: worktree).isEmpty else {
                throw TreeishError.recoveryRequired("rebase requires a clean worktree")
            }
            let ontoRecord = try CommitRecord(
                identifier: request.onto.bytes,
                object: store.read(identifier: request.onto.bytes)
            )
            try Repository.replaceWorktree(
                with: ontoRecord.tree,
                indexStore: indexStore,
                worktree: worktree,
                store: store
            )
            try Repository.publishReference(
                directory: refsDirectory,
                name: reference,
                value: request.onto,
                expected: original,
                requireMissing: false,
                reflog: nil
            )
            var state = RebaseState(
                original: original,
                currentHead: request.onto,
                reference: reference,
                current: nil,
                remaining: request.commits,
                author: request.author,
                committer: request.committer
            )
            try Repository.writeRebaseState(state, in: headDirectory)
            let result = try Repository.runRebase(
                state: &state,
                store: store,
                indexStore: indexStore,
                worktree: worktree,
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            if case .completed = result { try Repository.clearRebaseState(in: headDirectory) }
            return result
        }
    }

    public func continueRebase() -> GitOperation<RebaseResult> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        return GitOperation(phase: .reconciling) {
            guard let worktree else { throw TreeishError.repositoryNotFound }
            var state = try Repository.readRebaseState(from: headDirectory)
            guard let current = state.current else {
                throw TreeishError.recoveryRequired("rebase has no stopped commit")
            }
            let index = try indexStore.read()
            guard index.entries.allSatisfy({ $0.stage == 0 }) else {
                throw TreeishError.recoveryRequired("rebase conflicts remain unresolved")
            }
            let picked = try CommitRecord(
                identifier: current.bytes,
                object: store.read(identifier: current.bytes)
            )
            state.currentHead = try Repository.commitSequencerIndex(
                index: index,
                parent: state.currentHead,
                reference: state.reference,
                author: state.author,
                committer: state.committer,
                message: picked.message,
                store: store,
                refsDirectory: refsDirectory
            )
            state.current = nil
            try Repository.writeRebaseState(state, in: headDirectory)
            let result = try Repository.runRebase(
                state: &state,
                store: store,
                indexStore: indexStore,
                worktree: worktree,
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            if case .completed = result { try Repository.clearRebaseState(in: headDirectory) }
            return result
        }
    }

    public func abortRebase() -> GitOperation<ObjectID> {
        let store = objectStore
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        return GitOperation(phase: .reconciling) {
            guard let worktree else { throw TreeishError.repositoryNotFound }
            let state = try Repository.readRebaseState(from: headDirectory)
            let originalRecord = try CommitRecord(
                identifier: state.original.bytes,
                object: store.read(identifier: state.original.bytes)
            )
            try Repository.replaceWorktree(
                with: originalRecord.tree,
                indexStore: indexStore,
                worktree: worktree,
                store: store
            )
            try Repository.publishReference(
                directory: refsDirectory,
                name: state.reference,
                value: state.original,
                expected: state.currentHead,
                requireMissing: false,
                reflog: nil
            )
            try Repository.clearRebaseState(in: headDirectory)
            return state.original
        }
    }

    public func captureWorkspaceState() -> GitOperation<WorkspaceState> {
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let objectFormat = repositoryCapabilities.objectFormat
        return GitOperation(phase: .indexing) {
            guard let worktree else { throw TreeishError.repositoryNotFound }
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            let indexBytes = try indexStore.read().encode()
            let paths = try Repository.enumerateFiles(in: worktree)
            var entries: [WorkspaceStateEntry] = []
            var blobs: [[UInt8]: WorkspaceStateBlob] = [:]
            for path in paths {
                let url = try worktree.url(for: path.components, followFinalSymlink: false)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let type = attributes[.type] as? FileAttributeType
                let payload = try Repository.worktreePayload(url: url)
                let identifier = objectFormat.hash(payload)
                blobs[identifier] = WorkspaceStateBlob(identifier: identifier, bytes: payload)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
                let mode: UInt32 = type == .typeSymbolicLink
                    ? 0o120000
                    : (permissions & 0o111 == 0 ? 0o100644 : 0o100755)
                entries.append(
                    WorkspaceStateEntry(
                        path: path,
                        mode: mode,
                        contentIdentifier: identifier
                    )
                )
            }
            return WorkspaceState(
                headReference: head.reference,
                headObjectID: head.objectID,
                indexBytes: indexBytes,
                entries: entries.sorted { $0.path.bytes.lexicographicallyPrecedes($1.path.bytes) },
                blobs: blobs.values.sorted {
                    $0.identifier.lexicographicallyPrecedes($1.identifier)
                }
            )
        }
    }

    public func restoreWorkspaceState(
        _ state: WorkspaceState
    ) -> GitOperation<WorkspaceState> {
        let indexStore = indexStore
        let worktree = worktree
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let access = repositoryCapabilities.access
        let objectFormat = repositoryCapabilities.objectFormat
        return GitOperation(phase: .updatingWorktree) {
            guard case .readWrite = access, let worktree else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let blobMap = Dictionary(uniqueKeysWithValues: state.blobs.map {
                ($0.identifier, $0.bytes)
            })
            guard state.blobs.allSatisfy({
                objectFormat.hash($0.bytes) == $0.identifier
            }),
                  state.entries.allSatisfy({ blobMap[$0.contentIdentifier] != nil }) else {
                throw TreeishError.recoveryRequired("workspace state content verification failed")
            }
            let desired = Set(state.entries.map { $0.path })
            for path in try Repository.enumerateFiles(in: worktree) where !desired.contains(path) {
                let url = try worktree.url(for: path.components, followFinalSymlink: false)
                try FileManager.default.removeItem(at: url)
            }
            for entry in state.entries {
                guard let payload = blobMap[entry.contentIdentifier] else { continue }
                let url = try worktree.url(for: entry.path.components, followFinalSymlink: false)
                if entry.mode == 0o120000 {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    guard let target = String(bytes: payload, encoding: .utf8) else {
                        throw TreeishError.pathEncodingUnsupported
                    }
                    try FileManager.default.createSymbolicLink(
                        atPath: url.path,
                        withDestinationPath: target
                    )
                } else {
                    try worktree.writeAtomically(payload, to: entry.path.components)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: entry.mode == 0o100755 ? 0o755 : 0o644],
                        ofItemAtPath: url.path
                    )
                }
            }
            try indexStore.write(try GitIndex.decode(state.indexBytes))
            if let reference = state.headReference, let identifier = state.headObjectID {
                try Repository.publishCheckoutReferences(
                    headDirectory: headDirectory,
                    refsDirectory: refsDirectory,
                    reference: reference,
                    value: identifier
                )
            } else if let identifier = state.headObjectID {
                try Repository.publishDetachedHead(
                    headDirectory: headDirectory,
                    refsDirectory: refsDirectory,
                    value: identifier
                )
            }
            return state
        }
    }

    public func resolveReference(_ name: RefName) throws -> ObjectID {
        try resolveReference(name, visited: [])
    }

    public func resolveRevision(_ expression: String) throws -> ObjectID {
        guard !expression.isEmpty, expression.utf8.count <= 4096 else {
            throw TreeishError.invalidObjectID
        }
        if expression.hasSuffix("}"),
           let marker = expression.range(of: "@{", options: .backwards) {
            let base = String(expression[..<marker.lowerBound])
            let value = expression[marker.upperBound..<expression.index(before: expression.endIndex)]
            guard let index = Int(value), index >= 0, index <= 1_000_000 else {
                throw TreeishError.invalidObjectID
            }
            let components: [String]
            let directory: RootDirectory
            if base.isEmpty || base == "HEAD" {
                components = ["logs", "HEAD"]
                directory = gitDirectory
            } else {
                let name = try revisionReferenceName(base)
                components = ["logs"] + (try name.pathComponents)
                directory = commonDirectory
            }
            let bytes = try directory.read(
                components,
                limit: resourceLimits.maximumConfigBytes
            )
            let lines = Array(bytes.split(separator: 0x0a).reversed())
            guard lines.indices.contains(index) else {
                throw TreeishError.referenceNotFound
            }
            let fields = lines[index]
                .split(separator: 0x20, maxSplits: 2)
            guard fields.count >= 2 else {
                throw TreeishError.malformedReference
            }
            return try ObjectID(
                hex: String(decoding: fields[1], as: UTF8.self)
            )
        }
        if let colon = expression.firstIndex(of: ":"), colon != expression.startIndex {
            let base = try resolveRevision(String(expression[..<colon]))
            let path = try GitPath(String(expression[expression.index(after: colon)...]))
            let peeled = try peelToCommit(base)
            let record = try CommitRecord(
                identifier: peeled.bytes,
                object: objectStore.read(identifier: peeled.bytes)
            )
            let entries = try Repository.flattenTree(
                identifier: record.tree,
                prefix: [],
                store: objectStore
            )
            guard let match = entries.first(where: { $0.path == path.bytes }) else {
                throw TreeishError.invalidPath
            }
            return try ObjectID(bytes: match.objectID)
        }
        if expression.hasSuffix("^{tree}") {
            let base = try resolveRevision(String(expression.dropLast(7)))
            let peeled = try peelToCommit(base)
            let record = try CommitRecord(
                identifier: peeled.bytes,
                object: objectStore.read(identifier: peeled.bytes)
            )
            return try ObjectID(bytes: record.tree)
        }
        if expression.hasSuffix("^{}") {
            return try peelTag(try resolveRevision(String(expression.dropLast(3))))
        }
        if let operatorIndex = expression.lastIndex(where: { $0 == "^" || $0 == "~" }) {
            let baseText = String(expression[..<operatorIndex])
            if !baseText.isEmpty {
                let operation = expression[operatorIndex]
                let suffix = expression[expression.index(after: operatorIndex)...]
                let count = suffix.isEmpty ? 1 : Int(suffix)
                guard let count, count >= 0 else { throw TreeishError.invalidObjectID }
                var current = try peelToCommit(resolveRevision(baseText))
                if operation == "^" {
                    let record = try CommitRecord(
                        identifier: current.bytes,
                        object: objectStore.read(identifier: current.bytes)
                    )
                    guard count > 0, record.parents.indices.contains(count - 1) else {
                        throw TreeishError.referenceNotFound
                    }
                    return try ObjectID(bytes: record.parents[count - 1])
                }
                for _ in 0..<count {
                    let record = try CommitRecord(
                        identifier: current.bytes,
                        object: objectStore.read(identifier: current.bytes)
                    )
                    guard let parent = record.parents.first else {
                        throw TreeishError.referenceNotFound
                    }
                    current = try ObjectID(bytes: parent)
                }
                return current
            }
        }
        if expression == "HEAD" {
            guard let value = try readHead().objectID else { throw TreeishError.referenceNotFound }
            return value
        }
        if let identifier = try? ObjectID(hex: expression) {
            _ = try objectStore.read(identifier: identifier.bytes)
            return identifier
        }
        if let identifier = try objectStore.resolvePrefix(expression) {
            return try ObjectID(bytes: identifier)
        }
        var candidates: [ObjectID] = []
        let names = expression.hasPrefix("refs/")
            ? [expression]
            : [expression, "refs/heads/\(expression)", "refs/tags/\(expression)", "refs/remotes/\(expression)", "refs/remotes/\(expression)/HEAD"]
        for value in names {
            guard let name = try? RefName(value),
                  let identifier = try? resolveReference(name),
                  !candidates.contains(identifier) else { continue }
            candidates.append(identifier)
        }
        guard candidates.count == 1, let result = candidates.first else {
            throw candidates.isEmpty ? TreeishError.referenceNotFound : TreeishError.referenceChanged
        }
        return result
    }

    public func resolveRevisionRange(_ expression: String) throws -> RevisionRange {
        guard !expression.isEmpty, expression.utf8.count <= 4096 else {
            throw TreeishError.invalidObjectID
        }
        let kind: RevisionRange.Kind
        let delimiter: String
        if expression.contains("...") {
            kind = .symmetricDifference
            delimiter = "..."
        } else if expression.contains("..") {
            kind = .exclusion
            delimiter = ".."
        } else {
            throw TreeishError.invalidObjectID
        }
        let components = expression.components(separatedBy: delimiter)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty else {
            throw TreeishError.invalidObjectID
        }
        return RevisionRange(
            left: try resolveRevision(components[0]),
            right: try resolveRevision(components[1]),
            kind: kind
        )
    }

    private func revisionReferenceName(_ expression: String) throws -> RefName {
        let names = expression.hasPrefix("refs/")
            ? [expression]
            : [
                "refs/heads/\(expression)",
                "refs/tags/\(expression)",
                "refs/remotes/\(expression)",
            ]
        let resolved = names.compactMap { value -> RefName? in
            guard let name = try? RefName(value),
                  (try? resolveReference(name)) != nil else {
                return nil
            }
            return name
        }
        guard resolved.count == 1, let name = resolved.first else {
            throw resolved.isEmpty
                ? TreeishError.referenceNotFound
                : TreeishError.referenceChanged
        }
        return name
    }

    private func peelTag(_ identifier: ObjectID) throws -> ObjectID {
        try Repository.peelTag(identifier, store: objectStore)
    }

    private static func peelTag(
        _ identifier: ObjectID,
        store: RepositoryObjectStore
    ) throws -> ObjectID {
        var current = identifier
        var visited: Set<ObjectID> = []
        while true {
            guard visited.count < 16, visited.insert(current).inserted else {
                throw TreeishError.recoveryRequired("tag peel cycle")
            }
            let object = try store.read(identifier: current.bytes)
            guard object.type == .tag else { return current }
            guard let target = try Repository.tagTarget(object.payload) else {
                throw TreeishError.invalidObjectID
            }
            current = try ObjectID(bytes: target)
        }
    }

    private func peelToCommit(_ identifier: ObjectID) throws -> ObjectID {
        let peeled = try peelTag(identifier)
        guard try objectStore.read(identifier: peeled.bytes).type == .commit else {
            throw TreeishError.invalidObjectID
        }
        return peeled
    }

    public func updateReference(
        _ name: RefName,
        to newValue: ObjectID,
        expected: ObjectID? = nil,
        reflog: ReflogMetadata? = nil
    ) -> GitOperation<RefUpdateResult> {
        let directory = commonDirectory
        let store = objectStore
        let access = repositoryCapabilities.access
        let objectFormat = repositoryCapabilities.objectFormat
        return GitOperation(phase: .updatingRefs) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(
                    access.reason ?? .rootIsReadOnly
                )
            }
            guard newValue.algorithm == objectFormat else {
                throw TreeishError.invalidObjectID
            }
            let prior = try? Repository.readReference(
                directory: directory,
                name: name
            )
            if let expected, prior != expected {
                throw TreeishError.referenceChanged
            }
            try Repository.publishReference(
                directory: directory,
                name: name,
                value: newValue,
                expected: expected,
                requireMissing: false,
                reflog: reflog
            )
            if let original = try Repository.replacedIdentifier(
                name,
                objectFormat: objectFormat
            ) {
                store.setReplacement(
                    for: original.bytes,
                    to: newValue.bytes
                )
            }
            return RefUpdateResult(name: name, previous: prior, current: newValue)
        }
    }

    public func createBranch(
        named name: String,
        at target: ObjectID,
        reflog: ReflogMetadata? = nil
    ) -> GitOperation<RefUpdateResult> {
        createReference(namespace: "refs/heads", name: name, target: target, reflog: reflog)
    }

    public func createTag(_ request: TagRequest) -> GitOperation<RefUpdateResult> {
        let store = objectStore
        let directory = commonDirectory
        let access = repositoryCapabilities.access
        return GitOperation(phase: .updatingRefs) {
            guard case .readWrite = access,
                  request.target.algorithm == store.objectFormat else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let reference = try RefName("refs/tags/\(request.name)")
            let finalTarget: ObjectID
            let peeledTarget: ObjectID?
            if let tagger = request.tagger, let message = request.message {
                let targetObject = try store.read(identifier: request.target.bytes)
                let tag = GitObjectEncoder.tag(
                    objectHex: request.target.description,
                    objectType: targetObject.type,
                    name: request.name,
                    tagger: tagger.storageSignature,
                    message: message
                )
                finalTarget = try ObjectID(bytes: store.write(tag))
                peeledTarget = try Repository.peelTag(
                    request.target,
                    store: store
                )
            } else {
                finalTarget = request.target
                peeledTarget = nil
            }
            try Repository.publishReference(
                directory: directory,
                name: reference,
                value: finalTarget,
                expected: nil,
                requireMissing: true,
                reflog: nil,
                peeled: peeledTarget
            )
            return RefUpdateResult(name: reference, previous: nil, current: finalTarget)
        }
    }

    public func deleteReference(
        _ name: RefName,
        expected: ObjectID
    ) -> GitOperation<ObjectID> {
        let directory = commonDirectory
        let store = objectStore
        let access = repositoryCapabilities.access
        let objectFormat = repositoryCapabilities.objectFormat
        return GitOperation(phase: .updatingRefs) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            let current = try Repository.readReference(directory: directory, name: name)
            guard current == expected else { throw TreeishError.referenceChanged }
            try Repository.removeReference(
                directory: directory,
                name: name,
                expected: expected
            )
            if let original = try Repository.replacedIdentifier(
                name,
                objectFormat: objectFormat
            ) {
                store.setReplacement(for: original.bytes, to: nil)
            }
            return current
        }
    }

    public func listReferences(prefix: String = "refs/") -> GitOperation<[ReferenceInfo]> {
        let directory = commonDirectory
        return GitOperation(phase: .validating) {
            let values = try Repository.allReferences(directory: directory)
            return values.filter { $0.key.description.hasPrefix(prefix) }
                .map { ReferenceInfo(name: $0.key, objectID: $0.value) }
                .sorted { $0.name.bytes.lexicographicallyPrecedes($1.name.bytes) }
        }
    }

    private func createReference(
        namespace: String,
        name: String,
        target: ObjectID,
        reflog: ReflogMetadata?
    ) -> GitOperation<RefUpdateResult> {
        let directory = commonDirectory
        let store = objectStore
        let access = repositoryCapabilities.access
        let objectFormat = repositoryCapabilities.objectFormat
        return GitOperation(phase: .updatingRefs) {
            guard case .readWrite = access,
                  target.algorithm == objectFormat else {
                throw TreeishError.mutationDisabled(access.reason ?? .rootIsReadOnly)
            }
            _ = try store.read(identifier: target.bytes)
            let reference = try RefName("\(namespace)/\(name)")
            guard (try? Repository.readReference(
                directory: directory,
                name: reference
            )) == nil else { throw TreeishError.referenceChanged }
            try Repository.publishReference(
                directory: directory,
                name: reference,
                value: target,
                expected: nil,
                requireMissing: true,
                reflog: reflog
            )
            return RefUpdateResult(name: reference, previous: nil, current: target)
        }
    }

    public func commit(_ request: CommitRequest) -> GitOperation<CommitResult> {
        let headDirectory = gitDirectory
        let refsDirectory = commonDirectory
        let store = objectStore
        let access = repositoryCapabilities.access
        return GitOperation(phase: .updatingRefs) {
            guard case .readWrite = access else {
                throw TreeishError.mutationDisabled(
                    access.reason ?? .rootIsReadOnly
                )
            }
            let head = try Repository.readHead(
                headDirectory: headDirectory,
                refsDirectory: refsDirectory
            )
            guard let reference = head.reference else {
                throw TreeishError.malformedReference
            }
            if let expected = request.expectedHead, head.objectID != expected {
                throw TreeishError.referenceChanged
            }
            let object = GitObjectEncoder.commit(
                treeHex: request.tree.description,
                parentHexes: request.parents.map(\.description),
                author: request.author.storageSignature,
                committer: request.committer.storageSignature,
                message: request.message
            )
            let bytes = try store.write(object)
            let identifier = try ObjectID(bytes: bytes)
            try Repository.publishReference(
                directory: refsDirectory,
                name: reference,
                value: identifier,
                expected: head.objectID,
                requireMissing: head.objectID == nil,
                reflog: ReflogMetadata(
                    signature: request.committer,
                    message: "commit: \(String(decoding: request.message, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "")"
                )
            )
            return CommitResult(
                objectID: identifier,
                updatedReference: reference
            )
        }
    }

    private func readHead() throws -> (reference: RefName?, objectID: ObjectID?) {
        try Repository.readHead(
            headDirectory: gitDirectory,
            refsDirectory: commonDirectory
        )
    }

    private func resolveReference(
        _ name: RefName,
        visited: Set<RefName>
    ) throws -> ObjectID {
        _ = visited
        return try Repository.readReference(
            directory: commonDirectory,
            name: name
        )
    }

    private static func readHead(
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory
    ) throws -> (reference: RefName?, objectID: ObjectID?) {
        if try referenceStorage(directory: refsDirectory).format == .reftable {
            let head = try RefName("HEAD")
            let value = try ReftableStack(
                directory: headDirectory,
                objectFormat: referenceStorage(directory: refsDirectory).objectFormat
            ).reference(head)
            switch value {
            case .symbolic(let reference):
                return (
                    reference,
                    try? readReference(directory: refsDirectory, name: reference)
                )
            case .direct(let objectID, _):
                return (nil, objectID)
            case .deletion:
                return (nil, nil)
            }
        }
        let bytes = try headDirectory.read(["HEAD"], limit: 4096)
        guard let text = String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw TreeishError.malformedReference
        }
        if text.hasPrefix("ref: ") {
            let reference = try RefName(String(text.dropFirst(5)))
            let objectID = try? readReference(directory: refsDirectory, name: reference)
            return (reference, objectID)
        }
        return (nil, try ObjectID(hex: text))
    }

    private static func readDirectReference(
        directory: RootDirectory,
        components: [String]
    ) throws -> ObjectID {
        let bytes = try directory.read(components, limit: 4096)
        guard let text = String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw TreeishError.malformedReference
        }
        return try ObjectID(hex: text)
    }

    private static func readReference(
        directory: RootDirectory,
        name: RefName
    ) throws -> ObjectID {
        if try referenceStorage(directory: directory).format == .reftable {
            return try resolveReftableReference(
                directory: directory,
                name: name,
                visited: []
            )
        }
        do {
            return try readDirectReference(
                directory: directory,
                components: name.pathComponents
            )
        } catch RootDirectoryError.notFound {
            return try readPackedReference(directory: directory, name: name)
        }
    }

    private static func resolveReftableReference(
        directory: RootDirectory,
        name: RefName,
        visited: Set<RefName>
    ) throws -> ObjectID {
        guard visited.count < 16, !visited.contains(name) else {
            throw TreeishError.symbolicReferenceLoop
        }
        switch try readReferenceValue(directory: directory, name: name) {
        case .direct(let identifier, _):
            return identifier
        case .symbolic(let target):
            var next = visited
            next.insert(name)
            return try resolveReftableReference(
                directory: directory,
                name: target,
                visited: next
            )
        case .deletion:
            throw TreeishError.referenceNotFound
        }
    }

    private static func readReferenceValue(
        directory: RootDirectory,
        name: RefName
    ) throws -> ReftableReferenceValue {
        let storage = try referenceStorage(directory: directory)
        guard storage.format == .reftable else {
            throw TreeishError.malformedReference
        }
        let value = try ReftableStack(
            directory: directory,
            objectFormat: storage.objectFormat
        ).reference(name)
        if case .deletion = value {
            throw TreeishError.referenceNotFound
        }
        return value
    }

    private static func referenceStorage(
        directory: RootDirectory
    ) throws -> (format: RefStorageFormat, objectFormat: ObjectHashAlgorithm) {
        let configuration = try GitConfiguration.load(from: directory)
        let storage = configuration.value(
            section: "extensions",
            key: "refstorage"
        ).flatMap { RefStorageFormat(rawValue: $0.lowercased()) } ?? .files
        let objectFormat = configuration.value(
            section: "extensions",
            key: "objectformat"
        ).flatMap { ObjectHashAlgorithm(rawValue: $0.lowercased()) } ?? .sha1
        return (storage, objectFormat)
    }

    private static func readPackedReference(
        directory: RootDirectory,
        name: RefName
    ) throws -> ObjectID {
        let bytes = try directory.read(["packed-refs"], limit: 64 * 1024 * 1024)
        for line in bytes.split(separator: 0x0a) {
            guard line.first != 0x23, line.first != 0x5e else { continue }
            let fields = line.split(separator: 0x20, maxSplits: 1)
            guard fields.count == 2 else { continue }
            if Array(fields[1]) == name.bytes {
                return try ObjectID(hex: String(decoding: fields[0], as: UTF8.self))
            }
        }
        throw TreeishError.referenceNotFound
    }

    private static func packedReferences(
        directory: RootDirectory
    ) throws -> [RefName: ObjectID] {
        let bytes: [UInt8]
        do { bytes = try directory.read(["packed-refs"], limit: 64 * 1024 * 1024) }
        catch RootDirectoryError.notFound { return [:] }
        var result: [RefName: ObjectID] = [:]
        for line in bytes.split(separator: 0x0a) {
            guard line.first != 0x23, line.first != 0x5e else { continue }
            let fields = line.split(separator: 0x20, maxSplits: 1)
            guard fields.count == 2,
                  let name = try? RefName(validating: Array(fields[1])),
                  let identifier = try? ObjectID(hex: String(decoding: fields[0], as: UTF8.self))
            else { continue }
            result[name] = identifier
        }
        return result
    }

    private static func looseReferences(
        directory: RootDirectory
    ) throws -> [RefName: ObjectID] {
        let refsURL = try directory.url(for: ["refs"])
        guard let enumerator = FileManager.default.enumerator(
            at: refsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var values: [RefName: ObjectID] = [:]
        let basePath = refsURL.standardizedFileURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while let value = enumerator.nextObject() {
            guard let url = value as? URL else { continue }
            let candidate = url.standardizedFileURL.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard candidate.hasPrefix(basePath + "/") else { continue }
            let relative = String(candidate.dropFirst(basePath.count + 1))
            guard let name = try? RefName("refs/\(relative)"),
                  let identifier = try? readDirectReference(
                    directory: directory,
                    components: name.pathComponents
                  ) else { continue }
            values[name] = identifier
        }
        return values
    }

    private static func allReferences(
        directory: RootDirectory
    ) throws -> [RefName: ObjectID] {
        let storage = try referenceStorage(directory: directory)
        if storage.format == .reftable {
            let records = try ReftableStack(
                directory: directory,
                objectFormat: storage.objectFormat
            ).references()
            var values: [RefName: ObjectID] = [:]
            for (name, value) in records {
                guard name.description.hasPrefix("refs/") else { continue }
                switch value {
                case .direct(let identifier, _):
                    values[name] = identifier
                case .symbolic:
                    if let identifier = try? resolveReftableReference(
                        directory: directory,
                        name: name,
                        visited: []
                    ) {
                        values[name] = identifier
                    }
                case .deletion:
                    break
                }
            }
            return values
        }
        return try packedReferences(directory: directory).merging(
            looseReferences(directory: directory),
            uniquingKeysWith: { _, loose in loose }
        )
    }

    private static func replacementObjects(
        directory: RootDirectory,
        objectFormat: ObjectHashAlgorithm
    ) throws -> [[UInt8]: [UInt8]] {
        let prefix = "refs/replace/"
        var result: [[UInt8]: [UInt8]] = [:]
        for (name, target) in try allReferences(directory: directory)
        where name.description.hasPrefix(prefix) {
            let originalHex = String(name.description.dropFirst(prefix.count))
            let original = try ObjectID(
                hex: originalHex,
                algorithm: objectFormat
            )
            guard target.algorithm == objectFormat else {
                throw TreeishError.invalidObjectID
            }
            result[original.bytes] = target.bytes
        }
        return result
    }

    private static func replacedIdentifier(
        _ name: RefName,
        objectFormat: ObjectHashAlgorithm
    ) throws -> ObjectID? {
        let prefix = "refs/replace/"
        guard name.description.hasPrefix(prefix) else { return nil }
        return try ObjectID(
            hex: String(name.description.dropFirst(prefix.count)),
            algorithm: objectFormat
        )
    }

    private static func removePackedReference(
        directory: RootDirectory,
        name: RefName,
        expected: ObjectID
    ) throws {
        let original: [UInt8]
        do { original = try directory.read(["packed-refs"], limit: 64 * 1024 * 1024) }
        catch RootDirectoryError.notFound { return }
        var output: [UInt8] = []
        var removed = false
        for line in original.split(separator: 0x0a, omittingEmptySubsequences: false) {
            let fields = line.split(separator: 0x20, maxSplits: 1)
            if fields.count == 2, Array(fields[1]) == name.bytes {
                let value = try ObjectID(hex: String(decoding: fields[0], as: UTF8.self))
                guard value == expected else { throw TreeishError.referenceChanged }
                removed = true
                continue
            }
            output += line
            if line.endIndex != original.endIndex { output.append(0x0a) }
        }
        guard removed else { return }
        guard try directory.compareAndSwap(
            output,
            to: ["packed-refs"],
            expected: original
        ) else { throw TreeishError.referenceChanged }
    }

    private static func appendReflog(
        directory: RootDirectory,
        name: RefName,
        previous: ObjectID?,
        current: ObjectID,
        metadata: ReflogMetadata
    ) throws {
        let zero = String(
            repeating: "0",
            count: current.algorithm.byteCount * 2
        )
        let line = "\(previous?.description ?? zero) \(current.description) \(metadata.signature.storageSignature.encoded)\t\(metadata.message.replacingOccurrences(of: "\n", with: " "))\n"
        try directory.appendAtomically(
            Array(line.utf8),
            to: ["logs"] + name.pathComponents
        )
    }

    private static func publishReference(
        directory: RootDirectory,
        name: RefName,
        value: ObjectID,
        expected: ObjectID?,
        requireMissing: Bool,
        reflog: ReflogMetadata?,
        peeled: ObjectID? = nil
    ) throws {
        let storage = try referenceStorage(directory: directory)
        if storage.format == .reftable {
            let expectation: ReftableExpectedValue = if requireMissing {
                .missing
            } else if let expected {
                .direct(expected)
            } else {
                .any
            }
            try ReftableStack(
                directory: directory,
                objectFormat: storage.objectFormat
            ).append([
                ReftableUpdate(
                    name: name,
                    value: .direct(value, peeled: peeled),
                    expected: expectation,
                    reflog: reflog
                ),
            ])
            return
        }
        let components = try name.pathComponents
        let looseExists = try directory.exists(components)
        let expectedBytes = expected.map {
            Array("\($0.description)\n".utf8)
        }
        guard try directory.compareAndSwap(
            Array("\(value.description)\n".utf8),
            to: components,
            expected: looseExists ? expectedBytes : nil,
            requireMissing: requireMissing || (expected != nil && !looseExists)
        ) else { throw TreeishError.referenceChanged }
        if let reflog {
            try appendReflog(
                directory: directory,
                name: name,
                previous: expected,
                current: value,
                metadata: reflog
            )
        }
    }

    private static func removeReference(
        directory: RootDirectory,
        name: RefName,
        expected: ObjectID
    ) throws {
        let storage = try referenceStorage(directory: directory)
        if storage.format == .reftable {
            try ReftableStack(
                directory: directory,
                objectFormat: storage.objectFormat
            ).append([
                ReftableUpdate(
                    name: name,
                    value: .deletion,
                    expected: .direct(expected),
                    reflog: nil
                ),
            ])
            return
        }
        let components = try name.pathComponents
        if try directory.exists(components) {
            guard try directory.removeAtomically(
                components,
                expected: Array("\(expected.description)\n".utf8)
            ) else { throw TreeishError.referenceChanged }
        }
        try removePackedReference(
            directory: directory,
            name: name,
            expected: expected
        )
    }

    private static func publishCheckoutReferences(
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory,
        reference: RefName,
        value: ObjectID
    ) throws {
        let storage = try referenceStorage(directory: refsDirectory)
        if storage.format == .reftable {
            let prior = try? readReference(
                directory: refsDirectory,
                name: reference
            )
            let branchUpdate = ReftableUpdate(
                    name: reference,
                    value: .direct(value, peeled: nil),
                    expected: prior.map(ReftableExpectedValue.direct) ?? .missing,
                    reflog: nil
                )
            let headUpdate = ReftableUpdate(
                name: try RefName("HEAD"),
                value: .symbolic(reference),
                expected: .any,
                reflog: nil
            )
            if headDirectory.identity == refsDirectory.identity {
                try ReftableStack(
                    directory: refsDirectory,
                    objectFormat: storage.objectFormat
                ).append([headUpdate, branchUpdate])
            } else {
                try ReftableStack(
                    directory: refsDirectory,
                    objectFormat: storage.objectFormat
                ).append([branchUpdate])
                try ReftableStack(
                    directory: headDirectory,
                    objectFormat: storage.objectFormat
                ).append([headUpdate])
            }
            return
        }
        try headDirectory.writeAtomically(
            Array("ref: \(reference.description)\n".utf8),
            to: ["HEAD"]
        )
        try publishReference(
            directory: refsDirectory,
            name: reference,
            value: value,
            expected: nil,
            requireMissing: false,
            reflog: nil
        )
    }

    private static func publishDetachedHead(
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory,
        value: ObjectID
    ) throws {
        let storage = try referenceStorage(directory: refsDirectory)
        if storage.format == .reftable {
            try ReftableStack(
                directory: headDirectory,
                objectFormat: storage.objectFormat
            ).append([
                ReftableUpdate(
                    name: try RefName("HEAD"),
                    value: .direct(value, peeled: nil),
                    expected: .any,
                    reflog: nil
                ),
            ])
            return
        }
        try headDirectory.writeAtomically(
            Array("\(value.description)\n".utf8),
            to: ["HEAD"]
        )
    }

    private static func credential(
        for url: URL,
        services: RepositoryServices
    ) async throws -> GitCredential? {
        guard let provider = services.credentials, let host = url.host else {
            return nil
        }
        switch try await provider.credential(
            for: GitAuthenticationChallenge(
                scheme: "https",
                host: host,
                port: url.port,
                path: url.path
            )
        ) {
        case .use(let credential): return credential
        case .reject: return nil
        case .cancel: throw CancellationError()
        }
    }

    private static func materializePromisedObject(
        _ identifier: ObjectID,
        remoteName: String,
        services: RepositoryServices,
        store: RepositoryObjectStore,
        directory: RootDirectory
    ) async throws {
        let configuration = try GitConfiguration.load(from: directory)
        guard let value = configuration.value(
            section: "remote",
            subsection: remoteName,
            key: "url"
        ) else {
            throw TreeishError.referenceNotFound
        }
        let remote = try RemoteURL(value)
        let responseBody: [UInt8]
        let usesV2: Bool
        switch remote.transport {
        case .https:
            let credential = try await credential(
                for: remote.url,
                services: services
            )
            let client = SmartHTTPClient(
                transport: services.httpTransport
                    ?? URLSessionSmartHTTPTransport()
            )
            let advertisement = try await client.advertisement(
                remote: remote.url,
                authorization: credential?.authorizationHeader,
                protocolVersion: 2
            )
            var decoder = PacketLineDecoder()
            let packets = try decoder.append(advertisement.body)
            try decoder.finish()
            usesV2 = packets.contains {
                if case .data(let bytes) = $0 {
                    return bytes == Array("version 2\n".utf8)
                        || bytes == Array("version 2".utf8)
                }
                return false
            }
            let requestBody: [UInt8]
            if usesV2 {
                let capabilities = try UploadPackV2.parseCapabilities(
                    packets
                )
                requestBody = try UploadPackV2.fetchRequest(
                    wants: [identifier.bytes],
                    objectFormat: store.objectFormat,
                    capabilities: capabilities
                )
            } else {
                let advertisement = try UploadPackV0.parseAdvertisement(
                    packets
                )
                requestBody = try UploadPackV0.fetchRequest(
                    wants: [identifier.bytes],
                    objectFormat: store.objectFormat,
                    capabilities: advertisement.capabilities
                )
            }
            responseBody = try await client.uploadPack(
                remote: remote.url,
                body: requestBody,
                authorization: credential?.authorizationHeader
            ).body
        case .ssh:
            guard let endpoint = remote.sshEndpoint,
                  let transport = services.sshTransport else {
                throw TreeishError.remoteTransportUnavailable(.ssh)
            }
            let session = try await transport.open(
                SSHGitSessionRequest(
                    endpoint: endpoint,
                    service: .uploadPack
                )
            )
            var decoder = PacketLineDecoder()
            let packets = try decoder.append(
                try await session.advertisement()
            )
            try decoder.finish()
            let advertisement = try UploadPackV0.parseAdvertisement(packets)
            let requestBody = try UploadPackV0.fetchRequest(
                wants: [identifier.bytes],
                objectFormat: store.objectFormat,
                capabilities: advertisement.capabilities
            )
            responseBody = try await session.exchange(requestBody)
            usesV2 = false
        }
        let fetchResponse: UploadPackFetchResponse
        if usesV2 {
            var decoder = PacketLineDecoder()
            let packets = try decoder.append(responseBody)
            try decoder.finish()
            fetchResponse = try UploadPackV2.parseFetchResponse(packets)
        } else {
            fetchResponse = try UploadPackV0.parseFetchResponse(responseBody)
        }
        let pack = try PackReader.read(
            fetchResponse.pack,
            objectFormat: store.objectFormat,
            externalBase: { value in
                try? store.read(identifier: value)
            }
        )
        guard pack.objects.contains(where: {
            $0.identifier == identifier.bytes
        }) else {
            throw GitObjectError.objectNotFound
        }
        try publishPack(
            pack.objects,
            objectFormat: store.objectFormat,
            in: directory,
            promisor: true
        )
    }

    private static func readPromisedObject(
        _ identifier: [UInt8],
        preferredRemotes: [String],
        services: RepositoryServices,
        store: RepositoryObjectStore,
        directory: RootDirectory
    ) async throws -> GitObject {
        do {
            return try store.read(identifier: identifier)
        } catch GitObjectError.objectNotFound {
            let configured = try GitConfiguration.load(from: directory)
            let remotes = preferredRemotes.isEmpty
                ? promisorRemoteNames(configured)
                : preferredRemotes
            var lastError: any Error = GitObjectError.objectNotFound
            for remote in remotes {
                do {
                    try await materializePromisedObject(
                        try ObjectID(
                            algorithm: store.objectFormat,
                            bytes: identifier
                        ),
                        remoteName: remote,
                        services: services,
                        store: store,
                        directory: directory
                    )
                    return try store.read(identifier: identifier)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func configurePromisorRemote(
        name: String,
        url: RemoteURL,
        filter: GitObjectFilter,
        directory: RootDirectory
    ) throws {
        var configuration = try GitConfiguration(
            bytes: directory.read(["config"], limit: 16 * 1024 * 1024)
        )
        var bytes = try configuration.replacing(
            section: "core",
            key: "repositoryformatversion",
            value: "1"
        )
        configuration = try GitConfiguration(bytes: bytes)
        if configuration.value(
            section: "extensions",
            key: "partialclone"
        ) == nil {
            bytes = try configuration.replacing(
                section: "extensions",
                key: "partialclone",
                value: name
            )
            configuration = try GitConfiguration(bytes: bytes)
        }
        bytes = try configuration.replacing(
            section: "remote",
            subsection: name,
            key: "url",
            value: url.description
        )
        configuration = try GitConfiguration(bytes: bytes)
        bytes = try configuration.replacing(
            section: "remote",
            subsection: name,
            key: "promisor",
            value: "true"
        )
        configuration = try GitConfiguration(bytes: bytes)
        bytes = try configuration.replacing(
            section: "remote",
            subsection: name,
            key: "partialclonefilter",
            value: filter.rawValue
        )
        try directory.writeAtomically(bytes, to: ["config"])
    }

    private static func promisorRemoteNames(
        _ configuration: GitConfiguration
    ) -> [String] {
        var candidates: [String] = []
        for entry in configuration.entries
        where entry.section.caseInsensitiveCompare("remote") == .orderedSame {
            guard let name = entry.subsection,
                  !candidates.contains(name) else {
                continue
            }
            candidates.append(name)
        }
        var remotes = candidates.filter { name in
            guard let value = configuration.value(
                section: "remote",
                subsection: name,
                key: "promisor"
            )?.lowercased() else {
                return false
            }
            return ["true", "yes", "on", "1"].contains(value)
        }
        if let primary = configuration.value(
            section: "extensions",
            key: "partialclone"
        ), !primary.isEmpty {
            remotes.removeAll { $0 == primary }
            remotes.append(primary)
        }
        return remotes
    }

    private static func pruneFetchedReferences(
        positive: [FetchRefspec],
        negative: [FetchRefspec],
        advertisement: UploadPackAdvertisement,
        directory: RootDirectory
    ) throws -> [RefName] {
        let advertisedNames = Set(advertisement.references.map(\.name))
        let local = try allReferences(directory: directory)
        var pruned: Set<RefName> = []
        for refspec in positive where refspec.destination != nil {
            for (name, value) in local {
                guard !pruned.contains(name),
                      let remote = refspec.remoteReference(
                          for: name.bytes
                      ),
                      !advertisedNames.contains(remote),
                      !negative.contains(where: {
                          $0.matches(remote)
                      }) else {
                    continue
                }
                try removeReference(
                    directory: directory,
                    name: name,
                    expected: value
                )
                pruned.insert(name)
            }
        }
        return pruned.sorted {
            $0.bytes.lexicographicallyPrecedes($1.bytes)
        }
    }

    private static func publishPack(
        _ objects: [ResolvedPackObject],
        objectFormat: ObjectHashAlgorithm,
        in directory: RootDirectory,
        promisor: Bool = false
    ) throws {
        let canonical = try PackWriter.write(
            objects.map {
                try PackObject(identifier: $0.identifier, object: $0.object)
            },
            objectFormat: objectFormat
        )
        let checksum = canonical.checksum.map { String(format: "%02x", $0) }.joined()
        let token = UUID().uuidString.lowercased()
        let temporaryPack = ["objects", "pack", ".treeish-quarantine-\(token).pack"]
        let temporaryIndex = ["objects", "pack", ".treeish-quarantine-\(token).idx"]
        let temporaryPromisor = [
            "objects", "pack", ".treeish-quarantine-\(token).promisor",
        ]
        try directory.writeAtomically(canonical.pack, to: temporaryPack)
        do {
            try directory.writeAtomically(canonical.index, to: temporaryIndex)
            if promisor {
                try directory.writeAtomically([], to: temporaryPromisor)
                try directory.moveAtomically(
                    from: temporaryPromisor,
                    to: ["objects", "pack", "pack-\(checksum).promisor"]
                )
            }
            try directory.moveAtomically(
                from: temporaryPack,
                to: ["objects", "pack", "pack-\(checksum).pack"]
            )
            try directory.moveAtomically(
                from: temporaryIndex,
                to: ["objects", "pack", "pack-\(checksum).idx"]
            )
        } catch {
            for path in [
                temporaryPack, temporaryIndex, temporaryPromisor,
            ] {
                if let url = try? directory.url(for: path, followFinalSymlink: false) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            throw error
        }
    }

    private static func shallowIdentifiers(
        directory: RootDirectory,
        objectFormat: ObjectHashAlgorithm
    ) throws -> Set<[UInt8]> {
        let bytes: [UInt8]
        do {
            bytes = try directory.read(
                ["shallow"],
                limit: 16 * 1024 * 1024
            )
        } catch RootDirectoryError.notFound {
            return []
        }
        var result: Set<[UInt8]> = []
        for line in bytes.split(separator: 0x0a) {
            guard result.count < 1_000_000 else {
                throw TreeishError.recoveryRequired(
                    "shallow boundary limit exceeded"
                )
            }
            let identifier = try ObjectID(
                hex: String(decoding: line, as: UTF8.self),
                algorithm: objectFormat
            )
            result.insert(identifier.bytes)
        }
        return result
    }

    private static func publishShallowIdentifiers(
        _ identifiers: Set<[UInt8]>,
        directory: RootDirectory,
        objectFormat: ObjectHashAlgorithm
    ) throws {
        if identifiers.isEmpty {
            let url = try directory.url(
                for: ["shallow"],
                followFinalSymlink: false
            )
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        var bytes: [UInt8] = []
        for identifier in identifiers.sorted(by: {
            $0.lexicographicallyPrecedes($1)
        }) {
            let object = try ObjectID(
                algorithm: objectFormat,
                bytes: identifier
            )
            bytes += Array("\(object.description)\n".utf8)
        }
        try directory.writeAtomically(bytes, to: ["shallow"])
    }

    private static func reachablePackObjects(
        from start: [UInt8],
        excluding excluded: Set<[UInt8]>,
        store: RepositoryObjectStore,
        limit: Int = 1_000_000
    ) throws -> [PackObject] {
        var pending = [start]
        var visited: Set<[UInt8]> = []
        var result: [PackObject] = []
        while let identifier = pending.popLast() {
            guard visited.count < limit else {
                throw TreeishError.recoveryRequired("reachable object limit exceeded")
            }
            guard visited.insert(identifier).inserted, !excluded.contains(identifier) else {
                continue
            }
            let object = try store.read(identifier: identifier)
            result.append(try PackObject(identifier: identifier, object: object))
            switch object.type {
            case .commit:
                let commit = try CommitRecord(identifier: identifier, object: object)
                pending.append(commit.tree)
                pending.append(contentsOf: commit.parents)
            case .tree:
                pending.append(contentsOf: try treeObjectIDs(
                    object.payload,
                    objectFormat: store.objectFormat
                ))
            case .tag:
                if let target = try tagTarget(object.payload) { pending.append(target) }
            case .blob:
                break
            }
        }
        return result
    }

    private static func treeObjectIDs(
        _ payload: [UInt8],
        objectFormat: ObjectHashAlgorithm
    ) throws -> [[UInt8]] {
        var result: [[UInt8]] = []
        var cursor = 0
        while cursor < payload.count {
            guard let space = payload[cursor...].firstIndex(of: 0x20),
                  let nul = payload[space...].firstIndex(of: 0) else {
                throw GitObjectError.invalidHeader
            }
            let hashLength = objectFormat.byteCount
            guard nul + 1 + hashLength <= payload.count else {
                throw GitObjectError.invalidHeader
            }
            result.append(Array(payload[(nul + 1)..<(nul + 1 + hashLength)]))
            cursor = nul + 1 + hashLength
        }
        return result
    }

    private static func validWorktreeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    private static func linkedWorktrees(
        root: TreeishRoot,
        common: RootDirectory
    ) throws -> [LinkedWorktreeInfo] {
        guard try common.exists(["worktrees"]) else { return [] }
        let directory = try common.url(for: ["worktrees"])
        let identifiers = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var result: [LinkedWorktreeInfo] = []
        for identifier in identifiers where validWorktreeIdentifier(identifier) {
            let administration = ["worktrees", identifier]
            let gitFile = String(
                decoding: try common.read(administration + ["gitdir"], limit: 64 * 1024),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = URL(fileURLWithPath: gitFile).deletingLastPathComponent()
            let path = try GitPath(root.directory.relativeComponents(for: destination).joined(separator: "/"))
            let adminDirectory = try common.childDirectory(administration)
            guard let head = try readHead(
                headDirectory: adminDirectory,
                refsDirectory: common
            ).objectID else {
                throw TreeishError.referenceNotFound
            }
            let lockedReason: String?
            if let bytes = try? common.read(administration + ["locked"], limit: 4096) {
                lockedReason = String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else { lockedReason = nil }
            result.append(LinkedWorktreeInfo(
                identifier: identifier,
                path: path,
                head: head,
                lockedReason: lockedReason
            ))
        }
        return result
    }

    private struct FlatTreeEntry {
        let path: [UInt8]
        let objectID: [UInt8]
        let mode: UInt32
    }

    private struct RebaseState: Sendable, Codable {
        let original: ObjectID
        var currentHead: ObjectID
        let reference: RefName
        var current: ObjectID?
        var remaining: [ObjectID]
        let author: Signature
        let committer: Signature
    }

    private static func flattenTree(
        identifier: [UInt8],
        prefix: [UInt8],
        store: RepositoryObjectStore
    ) throws -> [FlatTreeEntry] {
        let object = try store.read(identifier: identifier)
        guard object.type == .tree else { throw GitObjectError.invalidHeader }
        var reader = CheckedByteReader(object.payload)
        var result: [FlatTreeEntry] = []
        while reader.remainingCount > 0 {
            var modeBytes: [UInt8] = []
            while true {
                let byte = try reader.readByte()
                if byte == 0x20 { break }
                modeBytes.append(byte)
            }
            var name: [UInt8] = []
            while true {
                let byte = try reader.readByte()
                if byte == 0 { break }
                name.append(byte)
            }
            guard !name.isEmpty, !name.contains(0x2f), name != Array(".git".utf8),
                  let parsedMode = UInt32(String(decoding: modeBytes, as: UTF8.self), radix: 8)
            else { throw GitObjectError.invalidHeader }
            let child = Array(try reader.read(
                count: store.objectFormat.byteCount
            ))
            let path = prefix.isEmpty ? name : prefix + [0x2f] + name
            if parsedMode == 0o40000 {
                result += try flattenTree(identifier: child, prefix: path, store: store)
            } else {
                result.append(FlatTreeEntry(path: path, objectID: child, mode: parsedMode))
            }
        }
        return result
    }

    private static func flattenPromisedTree(
        identifier: [UInt8],
        prefix: [UInt8],
        preferredRemotes: [String],
        services: RepositoryServices,
        store: RepositoryObjectStore,
        directory: RootDirectory
    ) async throws -> [FlatTreeEntry] {
        let object = try await readPromisedObject(
            identifier,
            preferredRemotes: preferredRemotes,
            services: services,
            store: store,
            directory: directory
        )
        guard object.type == .tree else {
            throw GitObjectError.invalidHeader
        }
        var reader = CheckedByteReader(object.payload)
        var result: [FlatTreeEntry] = []
        while reader.remainingCount > 0 {
            var modeBytes: [UInt8] = []
            while true {
                let byte = try reader.readByte()
                if byte == 0x20 { break }
                modeBytes.append(byte)
            }
            var name: [UInt8] = []
            while true {
                let byte = try reader.readByte()
                if byte == 0 { break }
                name.append(byte)
            }
            guard !name.isEmpty,
                  !name.contains(0x2f),
                  name != Array(".git".utf8),
                  let mode = UInt32(
                      String(decoding: modeBytes, as: UTF8.self),
                      radix: 8
                  ) else {
                throw GitObjectError.invalidHeader
            }
            let child = Array(try reader.read(
                count: store.objectFormat.byteCount
            ))
            let path = prefix.isEmpty ? name : prefix + [0x2f] + name
            if mode == 0o40000 {
                result += try await flattenPromisedTree(
                    identifier: child,
                    prefix: path,
                    preferredRemotes: preferredRemotes,
                    services: services,
                    store: store,
                    directory: directory
                )
            } else {
                result.append(
                    FlatTreeEntry(
                        path: path,
                        objectID: child,
                        mode: mode
                    )
                )
            }
        }
        return result
    }

    private static func worktreePayload(url: URL) throws -> [UInt8] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return Array(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
        }
        return Array(try Data(contentsOf: url))
    }

    private static func sameTreeEntry(
        _ left: FlatTreeEntry?,
        _ right: FlatTreeEntry?
    ) -> Bool {
        switch (left, right) {
        case (nil, nil): true
        case (.some(let left), .some(let right)):
            left.objectID == right.objectID && left.mode == right.mode
        default: false
        }
    }

    private static func mergeTrees(
        base: [[UInt8]: FlatTreeEntry],
        ours: [[UInt8]: FlatTreeEntry],
        theirs: [[UInt8]: FlatTreeEntry],
        worktree: RootDirectory,
        store: RepositoryObjectStore
    ) throws -> (entries: [GitIndexEntry], conflicts: [GitPath]) {
        var base = base
        var ours = ours
        var theirs = theirs
        let forcedConflicts = normalizeExactRenames(
            base: &base,
            ours: &ours,
            theirs: &theirs
        )
        let paths = Set(base.keys).union(ours.keys).union(theirs.keys)
        var indexEntries: [GitIndexEntry] = []
        var conflicts: [GitPath] = []
        for pathBytes in paths.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let ancestor = base[pathBytes]
            let left = ours[pathBytes]
            let right = theirs[pathBytes]
            let chosen: FlatTreeEntry?
            if forcedConflicts.contains(pathBytes) { chosen = nil }
            else if sameTreeEntry(left, right) { chosen = left }
            else if sameTreeEntry(ancestor, left) { chosen = right }
            else if sameTreeEntry(ancestor, right) { chosen = left }
            else {
                chosen = nil
                let path = try GitPath(bytes: pathBytes)
                if let merged = try contentMerge(
                    ancestor: ancestor,
                    ours: left,
                    theirs: right,
                    path: path,
                    store: store
                ) {
                    let identifier = try store.write(GitObject(type: .blob, payload: merged))
                    let mode = left?.mode ?? right?.mode ?? 0o100644
                    indexEntries.append(try GitIndexEntry(
                        path: pathBytes,
                        objectID: identifier,
                        mode: mode,
                        size: UInt32(min(merged.count, Int(UInt32.max))),
                        modificationSeconds: 0,
                        modificationNanoseconds: 0
                    ))
                    try worktree.writeAtomically(merged, to: path.components)
                    continue
                }
                conflicts.append(path)
                if let ancestor { indexEntries.append(try indexEntry(ancestor, stage: 1, store: store)) }
                if let left { indexEntries.append(try indexEntry(left, stage: 2, store: store)) }
                if let right { indexEntries.append(try indexEntry(right, stage: 3, store: store)) }
                try writeConflict(path: path, ours: left, theirs: right, worktree: worktree, store: store)
                continue
            }
            if let chosen {
                indexEntries.append(try indexEntry(chosen, stage: 0, store: store))
                try materializeFlatEntry(chosen, worktree: worktree, store: store)
            } else {
                let path = try GitPath(bytes: pathBytes)
                let url = try worktree.url(for: path.components, followFinalSymlink: false)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        return (indexEntries, conflicts)
    }

    private static func normalizeExactRenames(
        base: inout [[UInt8]: FlatTreeEntry],
        ours: inout [[UInt8]: FlatTreeEntry],
        theirs: inout [[UInt8]: FlatTreeEntry]
    ) -> Set<[UInt8]> {
        func renames(
            from base: [[UInt8]: FlatTreeEntry],
            to side: [[UInt8]: FlatTreeEntry]
        ) -> [[UInt8]: [UInt8]] {
            var result: [[UInt8]: [UInt8]] = [:]
            let additions = side.values.filter { base[$0.path] == nil }
            for (path, ancestor) in base where side[path] == nil {
                let matches = additions.filter {
                    $0.objectID == ancestor.objectID && $0.mode == ancestor.mode
                }
                if matches.count == 1 { result[path] = matches[0].path }
            }
            return result
        }
        let oursRenames = renames(from: base, to: ours)
        let theirsRenames = renames(from: base, to: theirs)
        var conflicts: Set<[UInt8]> = []
        for oldPath in Set(oursRenames.keys).union(theirsRenames.keys) {
            let oursDestination = oursRenames[oldPath]
            let theirsDestination = theirsRenames[oldPath]
            if let oursDestination, let theirsDestination,
               oursDestination != theirsDestination {
                conflicts.insert(oursDestination)
                conflicts.insert(theirsDestination)
                continue
            }
            guard let destination = oursDestination ?? theirsDestination,
                  let ancestor = base.removeValue(forKey: oldPath) else { continue }
            base[destination] = FlatTreeEntry(
                path: destination,
                objectID: ancestor.objectID,
                mode: ancestor.mode
            )
            if oursDestination == nil {
                if let value = ours.removeValue(forKey: oldPath) {
                    ours[destination] = FlatTreeEntry(
                        path: destination,
                        objectID: value.objectID,
                        mode: value.mode
                    )
                }
            } else {
                ours.removeValue(forKey: oldPath)
            }
            if theirsDestination == nil {
                if let value = theirs.removeValue(forKey: oldPath) {
                    theirs[destination] = FlatTreeEntry(
                        path: destination,
                        objectID: value.objectID,
                        mode: value.mode
                    )
                }
            } else {
                theirs.removeValue(forKey: oldPath)
            }
        }
        return conflicts
    }

    private static func materializeFlatEntry(
        _ entry: FlatTreeEntry,
        worktree: RootDirectory,
        store: RepositoryObjectStore,
        rules: WorkingTreeRules? = nil
    ) throws {
        let path = try GitPath(bytes: entry.path)
        let url = try worktree.url(for: path.components, followFinalSymlink: false)
        if try worktree.exists(path.components) {
            try FileManager.default.removeItem(at: url)
        }
        if entry.mode == 0o160000 {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return
        }
        let object = try store.read(identifier: entry.objectID)
        if entry.mode == 0o120000 {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: url.path,
                withDestinationPath: String(decoding: object.payload, as: UTF8.self)
            )
        } else {
            try worktree.writeAtomically(
                rules?.smudge(object.payload, path: path) ?? object.payload,
                to: path.components
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: entry.mode == 0o100755 ? 0o755 : 0o644],
                ofItemAtPath: url.path
            )
        }
    }

    private static func contentMerge(
        ancestor: FlatTreeEntry?,
        ours: FlatTreeEntry?,
        theirs: FlatTreeEntry?,
        path: GitPath,
        store: RepositoryObjectStore
    ) throws -> [UInt8]? {
        guard let ancestor, let ours, let theirs,
              ancestor.mode == ours.mode, ours.mode == theirs.mode,
              ancestor.mode == 0o100644 || ancestor.mode == 0o100755 else { return nil }
        let baseBytes = try store.read(identifier: ancestor.objectID).payload
        let oursBytes = try store.read(identifier: ours.objectID).payload
        let theirsBytes = try store.read(identifier: theirs.objectID).payload
        guard !baseBytes.contains(0), !oursBytes.contains(0), !theirsBytes.contains(0) else { return nil }
        if oursBytes == theirsBytes { return oursBytes }
        let baseLines = splitLines(baseBytes)
        let oursLines = splitLines(oursBytes)
        let theirsLines = splitLines(theirsBytes)
        guard let left = changedRange(base: baseLines, changed: oursLines),
              let right = changedRange(base: baseLines, changed: theirsLines),
              left.range.upperBound <= right.range.lowerBound || right.range.upperBound <= left.range.lowerBound
        else { return nil }
        let edits = [left, right].sorted { $0.range.lowerBound > $1.range.lowerBound }
        var merged = baseLines
        for edit in edits { merged.replaceSubrange(edit.range, with: edit.replacement) }
        return merged.flatMap { $0 }
    }

    private static func splitLines(_ bytes: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var line: [UInt8] = []
        for byte in bytes {
            line.append(byte)
            if byte == 0x0a { lines.append(line); line = [] }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    private static func changedRange(
        base: [[UInt8]],
        changed: [[UInt8]]
    ) -> (range: Range<Int>, replacement: [[UInt8]])? {
        var prefix = 0
        while prefix < base.count, prefix < changed.count, base[prefix] == changed[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < base.count - prefix,
              suffix < changed.count - prefix,
              base[base.count - 1 - suffix] == changed[changed.count - 1 - suffix] { suffix += 1 }
        guard prefix < base.count || prefix < changed.count else { return nil }
        return (
            prefix..<(base.count - suffix),
            Array(changed[prefix..<(changed.count - suffix)])
        )
    }

    private static func indexEntry(
        _ value: FlatTreeEntry,
        stage: UInt8,
        store: RepositoryObjectStore
    ) throws -> GitIndexEntry {
        let object = try store.read(identifier: value.objectID)
        return try GitIndexEntry(
            path: value.path,
            objectID: value.objectID,
            mode: value.mode,
            size: UInt32(min(object.payload.count, Int(UInt32.max))),
            modificationSeconds: 0,
            modificationNanoseconds: 0,
            stage: stage
        )
    }

    private static func submoduleConfigurations(
        worktree: RootDirectory
    ) throws -> [SubmoduleConfiguration] {
        guard try worktree.exists([".gitmodules"]) else {
            return []
        }
        let bytes = try worktree.read(
            [".gitmodules"],
            limit: 16 * 1024 * 1024
        )
        let document = try GitConfiguration(bytes: bytes)
        var names: [String] = []
        var fields: [String: [String: String]] = [:]
        for entry in document.entries
        where entry.section.caseInsensitiveCompare("submodule") == .orderedSame {
            guard let name = entry.subsection, !name.isEmpty else {
                throw TreeishError.invalidPath
            }
            if fields[name] == nil {
                names.append(name)
                fields[name] = [:]
            }
            fields[name]?[entry.key.lowercased()] = entry.value
        }
        var seenPaths: Set<[UInt8]> = []
        return try names.map { name in
            guard let values = fields[name],
                  let rawPath = values["path"] else {
                throw TreeishError.invalidPath
            }
            let path = try GitPath(rawPath)
            guard !path.bytes.isEmpty,
                  seenPaths.insert(path.bytes).inserted else {
                throw TreeishError.invalidPath
            }
            return SubmoduleConfiguration(
                name: name,
                path: path,
                url: values["url"],
                branch: values["branch"],
                update: values["update"],
                ignore: values["ignore"]
            )
        }
    }

    private static func join(
        _ parent: GitPath,
        _ child: GitPath
    ) throws -> GitPath {
        guard !parent.bytes.isEmpty else {
            return child
        }
        return try GitPath(bytes: parent.bytes + [0x2f] + child.bytes)
    }

    private static func worktreeStatus(
        index: GitIndex,
        worktree: RootDirectory
    ) throws -> [GitPath] {
        var result: [GitPath] = []
        for entry in index.entries {
            let path = try GitPath(bytes: entry.path)
            guard entry.stage == 0 else { result.append(path); continue }
            guard try worktree.exists(path.components) else {
                result.append(path)
                continue
            }
            let url = try worktree.url(for: path.components, followFinalSymlink: false)
            let payload = try worktreePayload(url: url)
            if index.objectFormat.hash(
                Array("blob \(payload.count)\0".utf8) + payload
            ) != entry.objectID {
                result.append(path)
            }
        }
        return result
    }

    private static func replaceWorktree(
        with tree: [UInt8],
        indexStore: GitIndexStore,
        worktree: RootDirectory,
        store: RepositoryObjectStore
    ) throws {
        let current = try indexStore.read()
        let target = try flattenTree(identifier: tree, prefix: [], store: store)
        let targetPaths = Set(target.map(\.path))
        for entry in current.entries where !targetPaths.contains(entry.path) {
            let path = try GitPath(bytes: entry.path)
            let url = try worktree.url(for: path.components, followFinalSymlink: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try materializeTree(identifier: tree, at: [], root: worktree, store: store)
        let entries = try target.map { try indexEntry($0, stage: 0, store: store) }
        try indexStore.write(GitIndex(
            version: current.version,
            objectFormat: current.objectFormat,
            entries: entries
        ))
    }

    private static func writeConflict(
        path: GitPath,
        ours: FlatTreeEntry?,
        theirs: FlatTreeEntry?,
        worktree: RootDirectory,
        store: RepositoryObjectStore
    ) throws {
        let oursBytes = try ours.map { try store.read(identifier: $0.objectID).payload }
        let theirsBytes = try theirs.map { try store.read(identifier: $0.objectID).payload }
        let url = try worktree.url(for: path.components, followFinalSymlink: false)
        guard let oursBytes, let theirsBytes,
              !oursBytes.contains(0), !theirsBytes.contains(0) else {
            if let oursBytes {
                try worktree.writeAtomically(oursBytes, to: path.components)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        var merged = Array("<<<<<<< HEAD\n".utf8)
        merged += oursBytes
        if merged.last != 0x0a { merged.append(0x0a) }
        merged += Array("=======\n".utf8)
        merged += theirsBytes
        if merged.last != 0x0a { merged.append(0x0a) }
        merged += Array(">>>>>>> MERGE_HEAD\n".utf8)
        try worktree.writeAtomically(merged, to: path.components)
    }

    private static func clearMergeState(in directory: RootDirectory) throws {
        for name in ["MERGE_HEAD", "MERGE_MSG", "ORIG_HEAD"] {
            let url = try directory.url(for: [name], followFinalSymlink: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func clearCherryPickState(in directory: RootDirectory) throws {
        for name in ["CHERRY_PICK_HEAD", "CHERRY_PICK_MSG", "ORIG_HEAD"] {
            let url = try directory.url(for: [name], followFinalSymlink: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func runRebase(
        state: inout RebaseState,
        store: RepositoryObjectStore,
        indexStore: GitIndexStore,
        worktree: RootDirectory,
        headDirectory: RootDirectory,
        refsDirectory: RootDirectory
    ) throws -> RebaseResult {
        while !state.remaining.isEmpty {
            let pickedID = state.remaining.removeFirst()
            state.current = pickedID
            try writeRebaseState(state, in: headDirectory)
            let picked = try CommitRecord(
                identifier: pickedID.bytes,
                object: store.read(identifier: pickedID.bytes)
            )
            let ours = try CommitRecord(
                identifier: state.currentHead.bytes,
                object: store.read(identifier: state.currentHead.bytes)
            )
            let baseTree: [UInt8]
            if let parent = picked.parents.first {
                baseTree = try CommitRecord(
                    identifier: parent,
                    object: store.read(identifier: parent)
                ).tree
            } else {
                baseTree = try store.write(GitObjectEncoder.tree(entries: []))
            }
            let base = Dictionary(uniqueKeysWithValues: try flattenTree(
                identifier: baseTree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let oursTree = Dictionary(uniqueKeysWithValues: try flattenTree(
                identifier: ours.tree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let theirsTree = Dictionary(uniqueKeysWithValues: try flattenTree(
                identifier: picked.tree, prefix: [], store: store
            ).map { ($0.path, $0) })
            let plan = try mergeTrees(
                base: base,
                ours: oursTree,
                theirs: theirsTree,
                worktree: worktree,
                store: store
            )
            let currentIndex = try indexStore.read()
            let index = GitIndex(
                version: currentIndex.version,
                objectFormat: currentIndex.objectFormat,
                entries: plan.entries
            )
            try indexStore.write(index)
            if !plan.conflicts.isEmpty {
                return .conflicted(commit: pickedID, paths: plan.conflicts)
            }
            state.currentHead = try commitSequencerIndex(
                index: index,
                parent: state.currentHead,
                reference: state.reference,
                author: state.author,
                committer: state.committer,
                message: picked.message,
                store: store,
                refsDirectory: refsDirectory
            )
            state.current = nil
            try writeRebaseState(state, in: headDirectory)
        }
        return .completed(state.currentHead)
    }

    private static func writeRebaseState(
        _ state: RebaseState,
        in directory: RootDirectory
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try directory.writeAtomically(
            Array(try encoder.encode(state)),
            to: ["rebase-treeish", "state.json"]
        )
    }

    private static func readRebaseState(from directory: RootDirectory) throws -> RebaseState {
        try JSONDecoder().decode(
            RebaseState.self,
            from: Data(directory.read(["rebase-treeish", "state.json"], limit: 16 * 1024 * 1024))
        )
    }

    private static func clearRebaseState(in directory: RootDirectory) throws {
        let url = try directory.url(for: ["rebase-treeish"], followFinalSymlink: false)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func commitSequencerIndex(
        index: GitIndex,
        parent: ObjectID,
        reference: RefName,
        author: Signature,
        committer: Signature,
        message: [UInt8],
        store: RepositoryObjectStore,
        refsDirectory: RootDirectory
    ) throws -> ObjectID {
        let items = index.entries.map {
            (components: $0.path.split(separator: 0x2f).map(Array.init), entry: $0)
        }
        let tree = try ObjectID(bytes: writeTree(items: items, store: store))
        let object = GitObjectEncoder.commit(
            treeHex: tree.description,
            parentHexes: [parent.description],
            author: author.storageSignature,
            committer: committer.storageSignature,
            message: message
        )
        let identifier = try ObjectID(bytes: store.write(object))
        try publishReference(
            directory: refsDirectory,
            name: reference,
            value: identifier,
            expected: parent,
            requireMissing: false,
            reflog: ReflogMetadata(
                signature: committer,
                message: "commit: \(String(decoding: message, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "")"
            )
        )
        return identifier
    }

    private static func tagTarget(_ payload: [UInt8]) throws -> [UInt8]? {
        guard let line = payload.split(separator: 0x0a).first(where: {
            $0.starts(with: Array("object ".utf8))
        }) else { return nil }
        return try ObjectID(hex: String(decoding: line.dropFirst(7), as: UTF8.self)).bytes
    }

    private static func inspectCapabilities(
        root: TreeishRoot,
        gitDirectory: RootDirectory,
        commonDirectory: RootDirectory
    ) throws -> RepositoryCapabilities {
        let configuration = try GitConfiguration.load(from: commonDirectory)
        let format = configuration.integer(
            section: "core",
            key: "repositoryformatversion"
        ) ?? 0
        var restrictions: [RepositoryRestriction] = []
        var extensions: [RepositoryExtensionCapability] = []
        if format < 0 || format > 1 {
            restrictions.append(
                RepositoryRestriction(reason: .repositoryFormat(format))
            )
        }
        var objectFormat = ObjectHashAlgorithm.sha1
        var refStorage = RefStorageFormat.files
        for (name, value) in configuration.values(in: "extensions") {
            let normalizedName = name.lowercased()
            let normalizedValue = value.lowercased()
            let understood: Bool
            switch normalizedName {
            case "objectformat":
                if let value = ObjectHashAlgorithm(rawValue: normalizedValue) {
                    objectFormat = value
                }
                understood = ObjectHashAlgorithm(rawValue: normalizedValue) != nil
            case "refstorage":
                if let value = RefStorageFormat(rawValue: normalizedValue) {
                    refStorage = value
                }
                understood = RefStorageFormat(rawValue: normalizedValue) != nil
            case "partialclone":
                understood = !value.isEmpty
            case "noop":
                understood = true
            default:
                understood = false
            }
            extensions.append(
                RepositoryExtensionCapability(
                    name: name,
                    value: value,
                    understood: understood
                )
            )
            if format == 1, !understood {
                restrictions.append(
                    RepositoryRestriction(reason: .requiredExtension(name))
                )
            }
        }
        let indexCapabilities: IndexCapabilities
        if try gitDirectory.exists(["index"]) {
            do {
                let index = try GitIndexStore(
                    gitDirectory: gitDirectory,
                    objectFormat: objectFormat
                ).read()
                indexCapabilities = IndexCapabilities(
                    version: Int(index.version),
                    canRead: true,
                    canWrite: true
                )
            } catch {
                indexCapabilities = IndexCapabilities(
                    version: nil,
                    canRead: false,
                    canWrite: false
                )
                restrictions.append(
                    RepositoryRestriction(
                        reason: .indexFormat(String(describing: error))
                    )
                )
            }
        } else {
            indexCapabilities = IndexCapabilities(
                version: nil,
                canRead: true,
                canWrite: true
            )
        }
        if root.policy.readOnly {
            restrictions.append(RepositoryRestriction(reason: .rootIsReadOnly))
        }
        let access: RepositoryAccess = restrictions.first.map {
            .readOnly(reason: $0.reason)
        } ?? .readWrite
        var operations: Set<RepositoryOperationCapability> = [
            .readObjects, .readRefs,
        ]
        if case .readWrite = access {
            operations.formUnion([
                .writeObjects, .updateRefs, .createCommit, .status, .stage,
                .checkout, .fetch, .push, .merge, .linkedWorktrees,
            ])
        }
        return RepositoryCapabilities(
            access: access,
            objectFormat: objectFormat,
            refStorage: refStorage,
            isShallow: try commonDirectory.exists(["shallow"]),
            usesAlternates: try commonDirectory.exists([
                "objects", "info", "alternates",
            ]),
            hasMultiPackIndex: try commonDirectory.exists([
                "objects", "pack", "multi-pack-index",
            ]) || commonDirectory.exists([
                "objects", "pack", "multi-pack-index.d",
                "multi-pack-index-chain",
            ]),
            promisorRemotes: promisorRemoteNames(configuration),
            index: indexCapabilities,
            repositoryExtensions: extensions,
            operations: operations,
            restrictions: restrictions
        )
    }

    private static func expandPathspecs(
        _ pathspecs: [GitPathspec],
        in worktree: RootDirectory,
        tracked: [[UInt8]]
    ) throws -> [GitPath] {
        var candidates = Set(try enumerateFiles(in: worktree))
        for bytes in tracked {
            candidates.insert(try GitPath(bytes: bytes))
        }
        return GitPathspec.select(candidates, using: pathspecs).sorted {
            $0.bytes.lexicographicallyPrecedes($1.bytes)
        }
    }

    private static func enumerateFiles(
        in worktree: RootDirectory,
        below path: GitPath = .root
    ) throws -> [GitPath] {
        let start = try worktree.url(for: path.components)
        guard let enumerator = FileManager.default.enumerator(
            at: start,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }
        var paths: [GitPath] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values.isDirectory == true { continue }
            let relative = try worktree.relativeComponents(for: url)
                .joined(separator: "/")
            if relative == ".git" || relative.hasPrefix(".git/") {
                continue
            }
            paths.append(try GitPath(relative))
        }
        return paths
    }

    private static func writeTree(
        items: [(components: [[UInt8]], entry: GitIndexEntry)],
        store: RepositoryObjectStore
    ) throws -> [UInt8] {
        var treeEntries: [GitTreeEntry] = []
        let direct = items.filter { $0.components.count == 1 }
        for item in direct {
            let mode: GitFileMode
            switch item.entry.mode {
            case 0o100755: mode = .executable
            case 0o120000: mode = .symbolicLink
            case 0o160000: mode = .gitlink
            default: mode = .regular
            }
            treeEntries.append(
                try GitTreeEntry(
                    mode: mode,
                    name: item.components[0],
                    objectID: item.entry.objectID
                )
            )
        }
        let grouped = Dictionary(
            grouping: items.filter { $0.components.count > 1 },
            by: { $0.components[0] }
        )
        for (name, children) in grouped {
            let nested = children.map {
                (components: Array($0.components.dropFirst()), entry: $0.entry)
            }
            let identifier = try writeTree(items: nested, store: store)
            treeEntries.append(
                try GitTreeEntry(
                    mode: .tree,
                    name: name,
                    objectID: identifier
                )
            )
        }
        return try store.write(GitObjectEncoder.tree(entries: treeEntries))
    }

    private static func materializeTree(
        identifier: [UInt8],
        at components: [String],
        root: RootDirectory,
        store: RepositoryObjectStore
    ) throws {
        let tree = try store.read(identifier: identifier)
        guard tree.type == .tree else { throw GitObjectError.invalidHeader }
        var reader = CheckedByteReader(tree.payload)
        while reader.remainingCount > 0 {
            var modeBytes: [UInt8] = []
            while true {
                let byte = try reader.readByte()
                if byte == 0x20 { break }
                modeBytes.append(byte)
            }
            var nameBytes: [UInt8] = []
            while true {
                let byte = try reader.readByte()
                if byte == 0 { break }
                nameBytes.append(byte)
            }
            guard let name = String(bytes: nameBytes, encoding: .utf8),
                  !name.isEmpty, name != ".", name != "..",
                  name.lowercased() != ".git", !name.contains("/") else {
                throw TreeishError.pathEncodingUnsupported
            }
            let objectID = Array(try reader.read(
                count: store.objectFormat.byteCount
            ))
            let mode = String(decoding: modeBytes, as: UTF8.self)
            let path = components + [name]
            if mode == "40000" || mode == "040000" {
                try root.createDirectory(path)
                try materializeTree(identifier: objectID, at: path, root: root, store: store)
            } else if mode == "160000" {
                try root.createDirectory(path)
            } else {
                let object = try store.read(identifier: objectID)
                guard object.type == .blob else { throw GitObjectError.invalidHeader }
                if mode == "120000" {
                    guard let target = String(bytes: object.payload, encoding: .utf8),
                          !target.isEmpty else { throw TreeishError.pathEncodingUnsupported }
                    let url = try root.url(for: path, followFinalSymlink: false)
                    if try root.exists(path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
                } else {
                    try root.writeAtomically(object.payload, to: path)
                    if mode == "100755" {
                        let url = try root.url(for: path, followFinalSymlink: false)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o755],
                            ofItemAtPath: url.path
                        )
                    }
                }
            }
        }
    }
}

private struct RepositoryCommitSource: CommitObjectSource {
    let store: RepositoryObjectStore

    func object(identifier: [UInt8]) async throws -> GitObject {
        try store.commitGraphObject(identifier: identifier)
    }
}

public enum GitObjectKind: String, Sendable, Hashable, Codable {
    case blob
    case tree
    case commit
    case tag

    fileprivate var storageType: GitObjectType {
        switch self {
        case .blob: .blob
        case .tree: .tree
        case .commit: .commit
        case .tag: .tag
        }
    }

    fileprivate init(storageType: GitObjectType) {
        switch storageType {
        case .blob: self = .blob
        case .tree: self = .tree
        case .commit: self = .commit
        case .tag: self = .tag
        }
    }
}

public struct StoredObject: Sendable, Hashable {
    public let type: GitObjectKind
    public let payload: [UInt8]

    public init(type: GitObjectKind, payload: [UInt8]) {
        self.type = type
        self.payload = payload
    }
}

private extension RepositoryAccess {
    var reason: CapabilityReason? {
        switch self {
        case .readWrite: nil
        case .readOnly(let reason), .metadataOnly(let reason): reason
        }
    }
}

private extension RefName {
    var pathComponents: [String] {
        get throws {
            guard let string = String(bytes: bytes, encoding: .utf8) else {
                throw TreeishError.pathEncodingUnsupported
            }
            return string.split(separator: "/").map(String.init)
        }
    }
}

private extension Signature {
    var storageSignature: GitSignature {
        GitSignature(
            name: name,
            email: email,
            secondsSinceEpoch: secondsSinceEpoch,
            timeZoneOffsetMinutes: timeZoneOffsetMinutes
        )
    }
}
