import Foundation
import Testing
@testable import Treeish

@Test func systemGitReadsTreeishLooseObject() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let operation = await repository.writeObject(
        type: .blob,
        payload: Array("interoperable\n".utf8)
    )
    let identifier = try await operation.value()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "cat-file", "-p", identifier.description]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(
        output.fileHandleForReading.readDataToEndOfFile() ==
        Data("interoperable\n".utf8)
    )
}

@Test func systemGitReadsTreeishIndexAndCommit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("hello\n".utf8).write(
        to: directory.appendingPathComponent("hello.txt")
    )

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let stage = await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("hello.txt")])
    )
    _ = try await stage.value()
    let tree = try await repository.writeIndexTree().value()
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("Initial commit\n".utf8)
        )
    ).value()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "status", "--porcelain"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    #expect(commit.objectID.description.count == 40)
}

@Test func treeishStatusSeparatesStagedAndWorktreeChanges() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    try Data("one\n".utf8).write(to: file)
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("file.txt")])
    ).value()
    let tree = try await repository.writeIndexTree().value()
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    _ = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("initial\n".utf8)
        )
    ).value()

    try Data("two\n".utf8).write(to: file)
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("file.txt")])
    ).value()
    #expect(try await repository.status().value().entries == [
        StatusEntry(path: try GitPath("file.txt"), indexChange: .modified),
    ])

    try Data("three\n".utf8).write(to: file)
    #expect(try await repository.status().value().entries == [
        StatusEntry(
            path: try GitPath("file.txt"),
            indexChange: .modified,
            worktreeChange: .modified
        ),
    ])
}

@Test func systemGitReadsTreeishUnifiedPatchWorktreeAndIndex() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("one\ntwo\n".utf8).write(
        to: directory.appendingPathComponent("file.txt")
    )
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("file.txt")])
    ).value()
    let result = try await repository.applyPatch(
        ApplyPatchRequest(
            patch: Array("""
            --- a/file.txt
            +++ b/file.txt
            @@ -1,2 +1,2 @@
             one
            -two
            +three
            """.utf8),
            updateIndex: true
        )
    ).value()
    #expect(result.updated == [try GitPath("file.txt")])
    #expect(
        try Data(contentsOf: directory.appendingPathComponent("file.txt"))
            == Data("one\nthree\n".utf8)
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "diff", "--cached", "--check"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func systemGitRecognizesTreeishLinkedWorktree() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let main = parent.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try Data("linked\n".utf8).write(to: main.appendingPathComponent("file.txt"))
    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.initialize(
        in: root,
        at: try GitPath("main")
    )
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("file.txt")])
    ).value()
    let tree = try await repository.writeIndexTree().value()
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("linked worktree\n".utf8)
        )
    ).value()
    let linked = try await repository.createLinkedWorktree(
        WorktreeRequest(
            destination: try GitPath("worker"),
            start: commit.objectID
        )
    ).value()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", main.path, "worktree", "list", "--porcelain"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let text = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    #expect(process.terminationStatus == 0)
    #expect(text.contains(parent.appendingPathComponent("worker").path))
    #expect(
        try Data(contentsOf: parent.appendingPathComponent("worker/file.txt"))
            == Data("linked\n".utf8)
    )
    #expect(try await repository.listLinkedWorktrees().value().contains {
        $0.identifier == linked.identifier && $0.path == linked.path
    })
    _ = try await repository.lockLinkedWorktree(
        identifier: linked.identifier,
        reason: "active agent"
    ).value()
    #expect(try await repository.listLinkedWorktrees().value().first?.lockedReason == "active agent")
    _ = try await repository.unlockLinkedWorktree(identifier: linked.identifier).value()
    #expect(try await repository.removeLinkedWorktree(identifier: linked.identifier).value() == linked.path)
    #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("worker").path))
}

@Test func systemGitVerifiesTreeishBundleAndCheckout() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("first\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    _ = try await repository.stage(StageRequest(pathspecs: [try GitPathspec("file.txt")])).value()
    let tree = try await repository.writeIndexTree().value()
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("bundle\n".utf8)
        )
    ).value()
    try Data("dirty\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
    do {
        _ = try await repository.checkout(
            CheckoutRequest(commit: commit.objectID, reference: try RefName("refs/heads/main"))
        ).value()
        Issue.record("checkout should protect dirty tracked files")
    } catch let error as TreeishError {
        guard case .worktreeCollision = error else {
            Issue.record("unexpected checkout error: \(error)")
            return
        }
    }
    try Data("first\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
    _ = try await repository.checkout(
        CheckoutRequest(commit: commit.objectID, reference: try RefName("refs/heads/main"))
    ).value()
    let bundle = try await repository.createBundle(
        references: [try RefName("refs/heads/main")]
    ).value()
    let bundleURL = directory.appendingPathComponent("repository.bundle")
    try Data(bundle.bytes).write(to: bundleURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "bundle", "verify", bundleURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func systemGitReadsTreeishMergeConflictsAndAbortRestores() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("conflict.txt")
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    func makeCommit(_ text: String, parents: [ObjectID]) async throws -> ObjectID {
        try Data(text.utf8).write(to: file)
        _ = try await repository.stage(StageRequest(pathspecs: [try GitPathspec("conflict.txt")])).value()
        let tree = try await repository.writeIndexTree().value()
        return try await repository.commit(
            CommitRequest(
                tree: tree,
                parents: parents,
                author: signature,
                committer: signature,
                message: Array("commit\n".utf8)
            )
        ).value().objectID
    }
    let base = try await makeCommit("base\n", parents: [])
    _ = try await repository.updateReference(
        try RefName("refs/heads/theirs"), to: base
    ).value()
    let ours = try await makeCommit("ours\n", parents: [base])
    _ = try await repository.checkout(
        CheckoutRequest(commit: base, reference: try RefName("refs/heads/theirs"))
    ).value()
    let theirs = try await makeCommit("theirs\n", parents: [base])
    _ = try await repository.checkout(
        CheckoutRequest(commit: ours, reference: try RefName("refs/heads/main"))
    ).value()
    let result = try await repository.merge(
        MergeRequest(
            other: theirs,
            author: signature,
            committer: signature,
            message: Array("merge\n".utf8)
        )
    ).value()
    guard case .conflicted(let paths) = result else {
        Issue.record("expected conflict")
        return
    }
    #expect(paths == [try GitPath("conflict.txt")])

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "ls-files", "-u"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let lines = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).split(separator: "\n")
    #expect(process.terminationStatus == 0)
    #expect(lines.count == 3)
    _ = try await repository.abortMerge().value()
    #expect(try Data(contentsOf: file) == Data("ours\n".utf8))
    #expect(try await repository.status().value().isClean)
}

@Test func treeishMergeCarriesModificationAcrossExactRenameAndPreservesSymlink() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    let renamed = directory.appendingPathComponent("renamed.txt")
    let link = directory.appendingPathComponent("current")
    try Data("base\n".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: "file.txt"
    )
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    func commit(_ message: String, parent: ObjectID?) async throws -> ObjectID {
        _ = try await repository.stage(
            StageRequest(pathspecs: [
                try GitPathspec("file.txt"),
                try GitPathspec("renamed.txt"),
                try GitPathspec("current"),
            ])
        ).value()
        let tree = try await repository.writeIndexTree().value()
        return try await repository.commit(
            CommitRequest(
                tree: tree,
                parents: parent.map { [$0] } ?? [],
                expectedHead: parent,
                author: signature,
                committer: signature,
                message: Array("\(message)\n".utf8)
            )
        ).value().objectID
    }
    let base = try await commit("base", parent: nil)
    _ = try await repository.updateReference(
        try RefName("refs/heads/theirs"),
        to: base
    ).value()

    try FileManager.default.moveItem(at: file, to: renamed)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: "renamed.txt"
    )
    let ours = try await commit("rename", parent: base)

    _ = try await repository.checkout(
        CheckoutRequest(commit: base, reference: try RefName("refs/heads/theirs"))
    ).value()
    try Data("modified on other side\n".utf8).write(to: file)
    let theirs = try await commit("modify", parent: base)

    _ = try await repository.checkout(
        CheckoutRequest(commit: ours, reference: try RefName("refs/heads/main"))
    ).value()
    let merge = try await repository.merge(
        MergeRequest(
            other: theirs,
            author: signature,
            committer: signature,
            message: Array("merge rename\n".utf8)
        )
    ).value()
    guard case .merged = merge else {
        Issue.record("expected clean rename/modify merge")
        return
    }
    #expect(try Data(contentsOf: renamed) == Data("modified on other side\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == "renamed.txt"
    )

    let status = Process()
    status.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    status.arguments = ["-C", directory.path, "status", "--porcelain"]
    let output = Pipe()
    status.standardOutput = output
    try status.run()
    status.waitUntilExit()
    #expect(status.terminationStatus == 0)
    #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
}

@Test func mergeConflictMatrixCoversDeleteBinaryAndFileSymlinkChanges() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let deleted = directory.appendingPathComponent("delete.txt")
    let binary = directory.appendingPathComponent("binary.dat")
    let typed = directory.appendingPathComponent("typed")
    try Data("base\n".utf8).write(to: deleted)
    try Data([0, 1, 2]).write(to: binary)
    try Data("regular\n".utf8).write(to: typed)
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    func commit(_ message: String, parent: ObjectID?) async throws -> ObjectID {
        _ = try await repository.stage(
            StageRequest(pathspecs: [
                try GitPathspec("delete.txt"),
                try GitPathspec("binary.dat"),
                try GitPathspec("typed"),
            ])
        ).value()
        let tree = try await repository.writeIndexTree().value()
        return try await repository.commit(
            CommitRequest(
                tree: tree,
                parents: parent.map { [$0] } ?? [],
                expectedHead: parent,
                author: signature,
                committer: signature,
                message: Array("\(message)\n".utf8)
            )
        ).value().objectID
    }
    let base = try await commit("base", parent: nil)
    _ = try await repository.updateReference(
        try RefName("refs/heads/theirs-matrix"),
        to: base
    ).value()

    try FileManager.default.removeItem(at: deleted)
    try Data([0, 3, 2]).write(to: binary)
    try FileManager.default.removeItem(at: typed)
    try FileManager.default.createSymbolicLink(
        atPath: typed.path,
        withDestinationPath: "delete.txt"
    )
    let ours = try await commit("ours", parent: base)

    _ = try await repository.checkout(
        CheckoutRequest(
            commit: base,
            reference: try RefName("refs/heads/theirs-matrix")
        )
    ).value()
    try Data("modified\n".utf8).write(to: deleted)
    try Data([0, 4, 2]).write(to: binary)
    try Data("changed regular\n".utf8).write(to: typed)
    let theirs = try await commit("theirs", parent: base)

    _ = try await repository.checkout(
        CheckoutRequest(
            commit: ours,
            reference: try RefName("refs/heads/main")
        )
    ).value()
    let result = try await repository.merge(
        MergeRequest(
            other: theirs,
            author: signature,
            committer: signature,
            message: Array("matrix merge\n".utf8)
        )
    ).value()
    guard case .conflicted(let conflicts) = result else {
        Issue.record("expected matrix conflicts")
        return
    }
    #expect(Set(conflicts.map(\.displayString)) == [
        "binary.dat", "delete.txt", "typed",
    ])

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "ls-files", "-u"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let text = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    #expect(process.terminationStatus == 0)
    for path in ["binary.dat", "delete.txt", "typed"] {
        #expect(text.contains("\t\(path)\n"))
    }
}

@Test func treeishReadsPackedRefsAndPublishesCASReflog() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("packed\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    _ = try await repository.stage(StageRequest(pathspecs: [try GitPathspec("file.txt")])).value()
    let tree = try await repository.writeIndexTree().value()
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("packed ref\n".utf8)
        )
    ).value()

    let packRefs = Process()
    packRefs.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    packRefs.arguments = ["-C", directory.path, "pack-refs", "--all", "--prune"]
    try packRefs.run()
    packRefs.waitUntilExit()
    #expect(packRefs.terminationStatus == 0)
    let main = try RefName("refs/heads/main")
    #expect(try await repository.resolveReference(main) == commit.objectID)
    #expect(
        try await repository.resolveRevision(
            String(commit.objectID.description.prefix(12))
        ) == commit.objectID
    )

    let wrong = try ObjectID(algorithm: .sha1, bytes: [UInt8](repeating: 0x11, count: 20))
    await #expect(throws: TreeishError.referenceChanged) {
        _ = try await repository.updateReference(
            main,
            to: commit.objectID,
            expected: wrong
        ).value()
    }
    _ = try await repository.updateReference(
        main,
        to: commit.objectID,
        expected: commit.objectID,
        reflog: ReflogMetadata(signature: signature, message: "treeish ref update")
    ).value()
    #expect(try await repository.resolveRevision("main@{0}") == commit.objectID)

    let reflog = Process()
    reflog.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    reflog.arguments = ["-C", directory.path, "reflog", "show", "main"]
    let output = Pipe()
    reflog.standardOutput = output
    try reflog.run()
    reflog.waitUntilExit()
    #expect(reflog.terminationStatus == 0)
    #expect(
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .contains("treeish ref update")
    )
}

@Test func treeishTraversesSystemGitDeltaPackAfterGC() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    var parent: ObjectID?
    for iteration in 0..<12 {
        let repeated = String(repeating: "shared line for delta compression\n", count: 400)
        try Data((repeated + "iteration \(iteration)\n").utf8).write(
            to: directory.appendingPathComponent("large.txt")
        )
        _ = try await repository.stage(
            StageRequest(pathspecs: [try GitPathspec("large.txt")])
        ).value()
        let tree = try await repository.writeIndexTree().value()
        parent = try await repository.commit(
            CommitRequest(
                tree: tree,
                parents: parent.map { [$0] } ?? [],
                expectedHead: parent,
                author: signature,
                committer: signature,
                message: Array("iteration \(iteration)\n".utf8)
            )
        ).value().objectID
    }
    let head = try #require(parent)
    let gc = Process()
    gc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    gc.arguments = ["-C", directory.path, "gc", "--aggressive", "--prune=now"]
    try gc.run()
    gc.waitUntilExit()
    #expect(gc.terminationStatus == 0)

    let reopenedRoot = try await TreeishRoot.localDirectory(at: directory)
    let reopened = try await Treeish.open(
        try await Treeish.discover(in: reopenedRoot),
        roots: [reopenedRoot]
    )
    let commits = try await reopened.log(from: [head], limit: 20).value()
    #expect(commits.count == 12)
    #expect(String(decoding: commits.first?.message ?? [], as: UTF8.self) == "iteration 11\n")
    #expect(try await reopened.status().value().isClean)
}

@Test func revisionRangesMatchGitReachabilitySemantics() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["-C", directory.path, "init", "-b", "main"]
    try git.run()
    git.waitUntilExit()
    #expect(git.terminationStatus == 0)
    for arguments in [
        ["config", "user.name", "Treeish"],
        ["config", "user.email", "treeish@example.com"],
    ] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    func commit(_ value: String) throws {
        try Data("\(value)\n".utf8).write(
            to: directory.appendingPathComponent("value.txt")
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", directory.path, "add", "value.txt",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commit.arguments = [
            "-C", directory.path, "commit", "-m", value,
        ]
        try commit.run()
        commit.waitUntilExit()
        #expect(commit.terminationStatus == 0)
    }
    try commit("base")
    let branch = Process()
    branch.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    branch.arguments = ["-C", directory.path, "branch", "base"]
    try branch.run()
    branch.waitUntilExit()
    #expect(branch.terminationStatus == 0)
    try commit("tip")

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    let exclusion = try await repository.resolveRevisionRange("base..main")
    #expect(exclusion.kind == .exclusion)
    #expect(
        try await repository.log(range: exclusion).value()
            .map { String(decoding: $0.message, as: UTF8.self) }
            == ["tip\n"]
    )
    let symmetric = try await repository.resolveRevisionRange("base...main")
    #expect(
        try await repository.log(range: symmetric).value().map(\.objectID)
            == [try await repository.resolveRevision("main")]
    )
}

@Test func treeishIgnoreAndAttributesMatchSystemGitCleanBytes() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("build"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("build/*\n!build/keep.txt\n".utf8).write(
        to: directory.appendingPathComponent(".gitignore")
    )
    try Data("*.txt text eol=lf\nsecret.bin filter=crypt\n".utf8).write(
        to: directory.appendingPathComponent(".gitattributes")
    )
    try Data("drop\n".utf8).write(to: directory.appendingPathComponent("build/drop.txt"))
    try Data("keep\r\n".utf8).write(to: directory.appendingPathComponent("build/keep.txt"))
    try Data("line one\r\nline two\r\n".utf8).write(
        to: directory.appendingPathComponent("content.txt")
    )
    try Data("secret".utf8).write(to: directory.appendingPathComponent("secret.bin"))
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let status = try await repository.status().value()
    #expect(!status.entries.contains { $0.path == (try? GitPath("build/drop.txt")) })
    #expect(status.entries.contains { $0.path == (try? GitPath("build/keep.txt")) })
    await #expect(throws: TreeishError.self) {
        _ = try await repository.stage(
            StageRequest(pathspecs: [try GitPathspec("build/drop.txt")])
        ).value()
    }
    await #expect(throws: TreeishError.self) {
        _ = try await repository.stage(
            StageRequest(pathspecs: [try GitPathspec("secret.bin")])
        ).value()
    }
    _ = try await repository.stage(
        StageRequest(pathspecs: [
            try GitPathspec(".gitignore"),
            try GitPathspec(".gitattributes"),
            try GitPathspec("build/keep.txt"),
            try GitPathspec("content.txt"),
        ])
    ).value()
    let tree = try await repository.writeIndexTree().value()
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    _ = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("attributes\n".utf8)
        )
    ).value()
    #expect(try await repository.status().value().entries == [
        StatusEntry(
            path: try GitPath("secret.bin"),
            worktreeChange: .untracked
        ),
    ])

    let show = Process()
    show.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    show.arguments = ["-C", directory.path, "show", "HEAD:content.txt"]
    let output = Pipe()
    show.standardOutput = output
    try show.run()
    show.waitUntilExit()
    #expect(show.terminationStatus == 0)
    #expect(
        output.fileHandleForReading.readDataToEndOfFile() ==
            Data("line one\nline two\n".utf8)
    )
}

@Test func treeishBundleImportPublishesCanonicalPack() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let sourceURL = parent.appendingPathComponent("source")
    let destinationURL = parent.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let sourceRoot = try await TreeishRoot.localDirectory(at: sourceURL)
    let source = try await Treeish.initialize(in: sourceRoot)
    try Data("packed bundle\n".utf8).write(to: sourceURL.appendingPathComponent("file.txt"))
    _ = try await source.stage(StageRequest(pathspecs: [try GitPathspec("file.txt")])).value()
    let tree = try await source.writeIndexTree().value()
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = try await source.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("packed bundle\n".utf8)
        )
    ).value()
    let bundle = try await source.createBundle(
        references: [try RefName("refs/heads/main")]
    ).value()

    let destinationRoot = try await TreeishRoot.localDirectory(at: destinationURL)
    let destination = try await Treeish.initialize(in: destinationRoot)
    let imported = try await destination.importBundle(bundle.bytes).value()
    #expect(imported.references[try RefName("refs/heads/main")] == commit.objectID)
    _ = try await destination.updateReference(
        try RefName("refs/heads/main"),
        to: commit.objectID
    ).value()

    let packDirectory = destinationURL.appendingPathComponent(".git/objects/pack")
    let packFiles = try FileManager.default.contentsOfDirectory(atPath: packDirectory.path)
    #expect(packFiles.filter { $0.hasSuffix(".pack") }.count == 1)
    #expect(packFiles.filter { $0.hasSuffix(".idx") }.count == 1)
    #expect(!packFiles.contains { $0.hasPrefix(".treeish-quarantine-") })

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", destinationURL.path, "cat-file", "-p", commit.objectID.description]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .contains("packed bundle")
    )
}

@Test func systemGitReadsTreeishBranchesAndAnnotatedTags() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    try Data("refs\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
    _ = try await repository.stage(StageRequest(pathspecs: [try GitPathspec("file.txt")])).value()
    let tree = try await repository.writeIndexTree().value()
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("refs\n".utf8)
        )
    ).value()
    let branch = try await repository.createBranch(named: "feature", at: commit.objectID).value()
    let tag = try await repository.createTag(TagRequest(
        name: "v1.0.0",
        target: commit.objectID,
        tagger: signature,
        message: Array("release\n".utf8)
    )).value()
    let references = try await repository.listReferences().value()
    #expect(references.contains { $0.name == branch.name && $0.objectID == commit.objectID })
    #expect(references.contains { $0.name == tag.name && $0.objectID == tag.current })

    let verify = Process()
    verify.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    verify.arguments = ["-C", directory.path, "cat-file", "-t", "v1.0.0"]
    let output = Pipe()
    verify.standardOutput = output
    try verify.run()
    verify.waitUntilExit()
    #expect(verify.terminationStatus == 0)
    #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "tag\n")

    let packRefs = Process()
    packRefs.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    packRefs.arguments = ["-C", directory.path, "pack-refs", "--all", "--prune"]
    try packRefs.run()
    packRefs.waitUntilExit()
    #expect(packRefs.terminationStatus == 0)
    _ = try await repository.deleteReference(branch.name, expected: commit.objectID).value()
    #expect(!(try await repository.listReferences().value()).contains { $0.name == branch.name })
}

@Test func systemGitReadsTreeishCherryPickWithNonOverlappingContentMerge() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    func commit(_ text: String, parents: [ObjectID], expected: ObjectID?) async throws -> ObjectID {
        try Data(text.utf8).write(to: file)
        _ = try await repository.stage(StageRequest(pathspecs: [try GitPathspec("file.txt")])).value()
        return try await repository.commit(CommitRequest(
            tree: try await repository.writeIndexTree().value(),
            parents: parents,
            expectedHead: expected,
            author: signature,
            committer: signature,
            message: Array("change\n".utf8)
        )).value().objectID
    }
    let base = try await commit("one\ntwo\nthree\n", parents: [], expected: nil)
    _ = try await repository.createBranch(named: "feature", at: base).value()
    let ours = try await commit("ONE\ntwo\nthree\n", parents: [base], expected: base)
    _ = try await repository.checkout(
        CheckoutRequest(commit: base, reference: try RefName("refs/heads/feature"))
    ).value()
    let picked = try await commit("one\ntwo\nTHREE\n", parents: [base], expected: base)
    _ = try await repository.checkout(
        CheckoutRequest(commit: ours, reference: try RefName("refs/heads/main"))
    ).value()
    let result = try await repository.cherryPick(CherryPickRequest(
        commit: picked,
        author: signature,
        committer: signature
    )).value()
    guard case .committed(let cherryPicked) = result else {
        Issue.record("expected cherry-pick commit")
        return
    }
    #expect(try Data(contentsOf: file) == Data("ONE\ntwo\nTHREE\n".utf8))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "show", "-s", "--format=%P", cherryPicked.description]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == ours.description
    )
}

@Test func systemGitReadsTreeishTypedMultiCommitRebase() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let signature = Signature(
        name: "Treeish", email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000, timeZoneOffsetMinutes: 0
    )
    func commit(_ text: String, parents: [ObjectID], expected: ObjectID?) async throws -> ObjectID {
        try Data(text.utf8).write(to: file)
        _ = try await repository.stage(StageRequest(pathspecs: [try GitPathspec("file.txt")])).value()
        return try await repository.commit(CommitRequest(
            tree: try await repository.writeIndexTree().value(),
            parents: parents,
            expectedHead: expected,
            author: signature,
            committer: signature,
            message: Array("rebase step\n".utf8)
        )).value().objectID
    }
    let base = try await commit("one\ntwo\nthree\n", parents: [], expected: nil)
    _ = try await repository.createBranch(named: "feature", at: base).value()
    _ = try await repository.checkout(
        CheckoutRequest(commit: base, reference: try RefName("refs/heads/feature"))
    ).value()
    let first = try await commit("one\nTWO\nthree\n", parents: [base], expected: base)
    let second = try await commit("one\nTWO\nTHREE\n", parents: [first], expected: first)
    _ = try await repository.checkout(
        CheckoutRequest(commit: base, reference: try RefName("refs/heads/main"))
    ).value()
    let onto = try await commit("ONE\ntwo\nthree\n", parents: [base], expected: base)
    _ = try await repository.checkout(
        CheckoutRequest(commit: second, reference: try RefName("refs/heads/feature"))
    ).value()
    let result = try await repository.rebase(RebaseRequest(
        onto: onto,
        commits: [first, second],
        author: signature,
        committer: signature
    )).value()
    guard case .completed(let rebased) = result else {
        Issue.record("expected completed rebase")
        return
    }
    #expect(try Data(contentsOf: file) == Data("ONE\nTWO\nTHREE\n".utf8))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "rev-list", "--first-parent", "--max-count=3", rebased.description]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let history = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    #expect(process.terminationStatus == 0)
    #expect(history.count == 3)
    #expect(history.last == onto.description)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/rebase-treeish").path))
}
