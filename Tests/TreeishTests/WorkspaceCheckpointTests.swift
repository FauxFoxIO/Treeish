import Foundation
import Testing
@testable import Treeish

private func checkpointGit(
    _ directory: URL,
    _ arguments: [String]
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_AUTHOR_NAME": "Treeish Tests",
        "GIT_AUTHOR_EMAIL": "tests@treeish.dev",
        "GIT_COMMITTER_NAME": "Treeish Tests",
        "GIT_COMMITTER_EMAIL": "tests@treeish.dev",
    ], uniquingKeysWith: { _, value in value })
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    guard process.terminationStatus == 0 else {
        Issue.record("git \(arguments.joined(separator: " ")) failed: \(text)")
        throw TreeishError.recoveryRequired("system Git fixture failed")
    }
    return text
}

@Test func workspaceCheckpointPreservesStagedAndFilesystemState() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    let destination = parent.appendingPathComponent("destination")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    _ = try checkpointGit(source, ["init"])
    try Data("A\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    try Data("remove\n".utf8).write(to: source.appendingPathComponent("remove.txt"))
    _ = try checkpointGit(source, ["add", "tracked.txt", "remove.txt"])
    _ = try checkpointGit(source, ["commit", "-m", "base"])

    try Data("B\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    try FileManager.default.removeItem(at: source.appendingPathComponent("remove.txt"))
    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root, from: try GitPath("source")),
        roots: [root]
    )
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("tracked.txt")])
    ).value()
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("remove.txt")])
    ).value()

    try Data("C\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    let binary = [UInt8]([0x00, 0xff, 0x41, 0x00, 0x7f])
    try Data(binary).write(to: source.appendingPathComponent("untracked.bin"))
    try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("link").path,
        withDestinationPath: "tracked.txt"
    )
    let executable = source.appendingPathComponent("tool")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
    )
    try FileManager.default.createDirectory(
        at: source.appendingPathComponent("empty"),
        withIntermediateDirectories: true
    )

    let checkpoint = try await repository.captureWorkspaceCheckpoint().value()
    let trackedPath = try GitPath("tracked.txt")
    let removedPath = try GitPath("remove.txt")
    let binaryPath = try GitPath("untracked.bin")
    let linkPath = try GitPath("link")
    let toolPath = try GitPath("tool")
    let emptyPath = try GitPath("empty")
    let index = try #require(checkpoint.indexEntries.first {
        $0.path == trackedPath && $0.stage == 0
    })
    #expect(
        try await repository.readObject(index.objectID).value().payload
            == Array("B\n".utf8)
    )
    #expect(checkpoint.deletedPaths.contains(removedPath))
    #expect(checkpoint.overlayEntries.contains {
        $0.path == binaryPath &&
            $0.origin == .untracked &&
            $0.mode == 0o100644
    })
    #expect(checkpoint.overlayEntries.contains {
        $0.path == linkPath && $0.kind == .symbolicLink
    })
    #expect(checkpoint.overlayEntries.contains {
        $0.path == toolPath && $0.mode == 0o100755
    })
    #expect(checkpoint.overlayEntries.contains {
        $0.path == emptyPath && $0.kind == .directory
    })

    let chunks = try await repository.exportWorkspaceCheckpoint(
        checkpoint,
        options: .init(maximumChunkBytes: 3)
    ).value()
    #expect(chunks.allSatisfy { $0.bytes.count <= 3 })
    let receiver = try await Treeish.initialize(
        in: root,
        at: try GitPath("receiver"),
        options: RepositoryInitialization(
            objectFormat: checkpoint.objectFormat
        )
    )
    #expect(
        try await receiver.missingWorkspaceCheckpointObjects(for: checkpoint)
            .value() == checkpoint.requiredObjectIDs
    )
    let original = try #require(chunks.first(where: { !$0.bytes.isEmpty }))
    var alteredBytes = original.bytes
    alteredBytes[0] ^= 0x01
    let altered = try GitWorkspaceCheckpointObjectChunk(
        objectID: original.objectID,
        objectType: original.objectType,
        objectByteCount: original.objectByteCount,
        byteOffset: original.byteOffset,
        bytes: alteredBytes
    )
    let corrupt = chunks.map { $0 == original ? altered : $0 }
    await #expect(throws: GitWorkspaceCheckpointError.invalidChunk) {
        _ = try await receiver.importWorkspaceCheckpoint(
            checkpoint,
            chunks: corrupt
        ).value()
    }
    _ = try await receiver.importWorkspaceCheckpoint(
        checkpoint,
        chunks: chunks
    ).value()
    #expect(
        try await receiver.missingWorkspaceCheckpointObjects(for: checkpoint)
            .value().isEmpty
    )
    let materialized = try await repository.materializeWorkspaceCheckpoint(
        checkpoint,
        at: try GitPath("destination"),
        options: .init(maximumChunkBytes: 3)
    ).value()
    #expect(materialized.operationContinuation == .unavailable)
    #expect(
        try checkpointGit(destination, ["show", ":tracked.txt"])
            == "B\n"
    )
    #expect(try Data(contentsOf: destination.appendingPathComponent("tracked.txt")) == Data("C\n".utf8))
    #expect(try Data(contentsOf: destination.appendingPathComponent("untracked.bin")) == Data(binary))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("link").path
        ) == "tracked.txt"
    )
    let toolPermissions = try #require(
        (try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("tool").path
        )[.posixPermissions] as? NSNumber)?.uint16Value
    )
    #expect(toolPermissions & 0o111 != 0)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("empty").path,
        isDirectory: &isDirectory
    ) && isDirectory.boolValue)
    let porcelain = try checkpointGit(destination, ["status", "--porcelain"])
    #expect(porcelain.contains("MM tracked.txt"))
    #expect(porcelain.contains("D  remove.txt"))
    #expect(try checkpointGit(destination, ["fsck", "--no-dangling"]).isEmpty)
}

@Test func workspaceCheckpointInstallsIntoCleanLinkedWorktree() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    let linkedPath = parent.appendingPathComponent("Work/receiver")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    _ = try checkpointGit(source, ["init"])
    try Data("A\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    _ = try checkpointGit(source, ["add", "tracked.txt"])
    _ = try checkpointGit(source, ["commit", "-m", "base"])

    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root, from: try GitPath("source")),
        roots: [root]
    )
    try Data("B\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("tracked.txt")])
    ).value()
    try Data("C\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    try Data([0x00, 0xff, 0x41]).write(
        to: source.appendingPathComponent("untracked.bin")
    )
    let checkpoint = try await repository.captureWorkspaceCheckpoint().value()
    let sourceContext = await repository.workspaceCheckpointContext()
    let objectIDsBeforeInstall = try sourceContext.objectStore.allIdentifiers()
    let ordinaryReferenceBefore = try checkpointGit(
        source,
        ["rev-parse", "refs/heads/main"]
    )
    let generation = try ObjectID(hex: ordinaryReferenceBefore
        .trimmingCharacters(in: .whitespacesAndNewlines))
    let worktree = try await repository.createLinkedWorktree(
        WorktreeRequest(
            destination: try GitPath("Work/receiver"),
            start: generation
        )
    ).value()
    let linked = try await Treeish.open(
        try await Treeish.discover(
            in: root,
            from: try GitPath("Work/receiver")
        ),
        roots: [root]
    )

    try Data("busy\n".utf8).write(to: linkedPath.appendingPathComponent("busy.txt"))
    await #expect(throws: GitWorkspaceCheckpointError.destinationIsActive) {
        _ = try await linked.installWorkspaceCheckpoint(
            checkpoint,
            expectedGeneration: worktree.head
        ).value()
    }
    #expect(try Data(contentsOf: linkedPath.appendingPathComponent("tracked.txt")) == Data("A\n".utf8))
    #expect(try checkpointGit(source, ["rev-parse", "refs/heads/main"]) == ordinaryReferenceBefore)
    try FileManager.default.removeItem(at: linkedPath.appendingPathComponent("busy.txt"))

    let receipt = try await linked.installWorkspaceCheckpoint(
        checkpoint,
        expectedGeneration: worktree.head
    ).value()
    #expect(receipt.location == linked.identity.location)
    #expect(receipt.operationContinuation == .unavailable)
    #expect(try sourceContext.objectStore.allIdentifiers() == objectIDsBeforeInstall)
    #expect(try checkpointGit(source, ["rev-parse", "refs/heads/main"]) == ordinaryReferenceBefore)
    #expect(try checkpointGit(linkedPath, ["show", ":tracked.txt"]) == "B\n")
    #expect(try Data(contentsOf: linkedPath.appendingPathComponent("tracked.txt")) == Data("C\n".utf8))
    #expect(
        try Data(contentsOf: linkedPath.appendingPathComponent("untracked.bin"))
            == Data([0x00, 0xff, 0x41])
    )
}

@Test func workspaceCheckpointInstallsIntoCleanPrimaryWorktree() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    _ = try checkpointGit(source, ["init"])
    try Data("secret.txt\n".utf8).write(
        to: source.appendingPathComponent(".gitignore")
    )
    try Data("A\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    _ = try checkpointGit(source, ["add", ".gitignore", "tracked.txt"])
    _ = try checkpointGit(source, ["commit", "-m", "base"])

    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root, from: try GitPath("source")),
        roots: [root]
    )
    let generation = try await repository.resolveRevision("HEAD")
    let ordinaryReferenceBefore = try checkpointGit(
        source,
        ["rev-parse", "refs/heads/main"]
    )
    try Data("B\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("tracked.txt")])
    ).value()
    try Data("C\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    try Data("local\n".utf8).write(to: source.appendingPathComponent("untracked.txt"))
    let checkpoint = try await repository.captureWorkspaceCheckpoint(
        GitWorkspaceCheckpointCaptureOptions(ignoredFiles: .exclude)
    ).value()

    _ = try checkpointGit(source, ["reset", "--hard", "HEAD"])
    try FileManager.default.removeItem(at: source.appendingPathComponent("untracked.txt"))
    try Data("preserve me\n".utf8).write(
        to: source.appendingPathComponent("secret.txt")
    )
    _ = try await repository.installWorkspaceCheckpoint(
        checkpoint,
        expectedGeneration: generation
    ).value()

    #expect(try checkpointGit(source, ["rev-parse", "refs/heads/main"]) == ordinaryReferenceBefore)
    #expect(try checkpointGit(source, ["show", ":tracked.txt"]) == "B\n")
    #expect(try Data(contentsOf: source.appendingPathComponent("tracked.txt")) == Data("C\n".utf8))
    #expect(try Data(contentsOf: source.appendingPathComponent("untracked.txt")) == Data("local\n".utf8))
    #expect(try Data(contentsOf: source.appendingPathComponent("secret.txt")) == Data("preserve me\n".utf8))
}

@Test func workspaceCheckpointReplacesOnlyMatchingDirtyState() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    _ = try checkpointGit(source, ["init"])
    try Data("secret.txt\n".utf8).write(
        to: source.appendingPathComponent(".gitignore")
    )
    try Data("A\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    _ = try checkpointGit(source, ["add", ".gitignore", "tracked.txt"])
    _ = try checkpointGit(source, ["commit", "-m", "base"])
    try Data("keep local\n".utf8).write(
        to: source.appendingPathComponent("secret.txt")
    )

    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root, from: try GitPath("source")),
        roots: [root]
    )
    let options = GitWorkspaceCheckpointCaptureOptions(ignoredFiles: .exclude)
    let clean = try await repository.captureWorkspaceCheckpoint(options).value()
    try Data("B\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("tracked.txt")])
    ).value()
    try Data("C\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    try Data("remove me\n".utf8).write(
        to: source.appendingPathComponent("untracked.txt")
    )
    let dirty = try await repository.captureWorkspaceCheckpoint(options).value()

    try Data("drift\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    await #expect(throws: GitWorkspaceCheckpointError.destinationIsActive) {
        _ = try await repository.replaceWorkspaceCheckpoint(
            dirty,
            with: clean
        ).value()
    }
    #expect(try Data(contentsOf: source.appendingPathComponent("tracked.txt")) == Data("drift\n".utf8))

    try Data("C\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    _ = try await repository.replaceWorkspaceCheckpoint(
        dirty,
        with: clean
    ).value()
    #expect(try Data(contentsOf: source.appendingPathComponent("tracked.txt")) == Data("A\n".utf8))
    #expect(!FileManager.default.fileExists(
        atPath: source.appendingPathComponent("untracked.txt").path
    ))
    #expect(try Data(contentsOf: source.appendingPathComponent("secret.txt")) == Data("keep local\n".utf8))
    #expect(try checkpointGit(source, ["status", "--porcelain"]).isEmpty)
}

@Test func workspaceCheckpointCapturesUnbornAndDetachedHead() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    let root = try await TreeishRoot.localDirectory(at: parent)
    let unborn = try await Treeish.initialize(in: root, at: try GitPath("source"))
    let unbornCheckpoint = try await unborn.captureWorkspaceCheckpoint().value()
    guard case .attached(let reference, let objectID) = unbornCheckpoint.head else {
        Issue.record("expected an unborn attached HEAD")
        return
    }
    #expect(reference.description == "refs/heads/main")
    #expect(objectID == nil)

    try Data("value\n".utf8).write(to: source.appendingPathComponent("value.txt"))
    _ = try checkpointGit(source, ["add", "value.txt"])
    _ = try checkpointGit(source, ["commit", "-m", "base"])
    let expected = try ObjectID(hex: try checkpointGit(source, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines))
    _ = try checkpointGit(source, ["checkout", "--detach"])
    let detached = try await Treeish.open(
        try await Treeish.discover(in: root, from: try GitPath("source")),
        roots: [root]
    )
    let detachedCheckpoint = try await detached.captureWorkspaceCheckpoint().value()
    #expect(detachedCheckpoint.head == .detached(objectID: expected))
}

@Test func workspaceCheckpointRejectsStateChangingCaptureWithoutPublishing() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    _ = try checkpointGit(source, ["init"])
    try Data("base\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    _ = try checkpointGit(source, ["add", "tracked.txt"])
    _ = try checkpointGit(source, ["commit", "-m", "base"])

    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root, from: try GitPath("source")),
        roots: [root]
    )
    let context = await repository.workspaceCheckpointContext()
    let worktree = try #require(context.worktree)
    let objectIDsBefore = try context.objectStore.allIdentifiers()

    #expect(throws: GitWorkspaceCheckpointError.changedDuringCapture) {
        try WorkspaceCheckpointOperations.capture(
            options: .init(),
            worktree: worktree,
            headDirectory: context.gitDirectory,
            refsDirectory: context.commonDirectory,
            store: context.objectStore,
            limits: context.resourceLimits,
            beforeStabilityValidation: {
                try Data("changed\n".utf8).write(
                    to: source.appendingPathComponent("tracked.txt")
                )
            }
        )
    }
    #expect(try context.objectStore.allIdentifiers() == objectIDsBefore)
}

@Test func workspaceCheckpointRejectsCorruptChunksAndUnsafeManifestPaths() async throws {
    let identifier = try ObjectID(
        algorithm: .sha1,
        bytes: [UInt8](repeating: 1, count: 20)
    )
    let overlay = try GitWorkspaceCheckpointOverlayEntry(
        path: try GitPath("safe"),
        kind: .regularFile,
        origin: .untracked,
        mode: 0o100644,
        contentObjectID: identifier
    )
    let checkpoint = try GitWorkspaceCheckpoint(
        objectFormat: .sha1,
        head: .attached(reference: try RefName("refs/heads/main"), objectID: nil),
        indexVersion: 2,
        indexEntries: [],
        overlayEntries: [overlay],
        deletedPaths: [],
        ignoredFiles: .include,
        objectRoots: [identifier],
        requiredObjectIDs: [identifier]
    )
    #expect(throws: GitWorkspaceCheckpointError.self) {
        _ = try GitWorkspaceCheckpointObjectChunk(
            objectID: identifier,
            objectType: .blob,
            objectByteCount: 1,
            byteOffset: 0,
            bytes: [0],
            contentDigest: [UInt8](repeating: 0, count: 32)
        )
    }

    var document = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(checkpoint)
        ) as? [String: Any]
    )
    var entries = try #require(document["overlayEntries"] as? [[String: Any]])
    var entry = try #require(entries.first)
    var path = try #require(entry["path"] as? [String: Any])
    path["bytes"] = [46, 46]
    entry["path"] = path
    entries[0] = entry
    document["overlayEntries"] = entries
    let malformed = try JSONSerialization.data(withJSONObject: document)
    #expect(throws: Error.self) {
        _ = try JSONDecoder().decode(
            GitWorkspaceCheckpoint.self,
            from: malformed
        )
    }
}
