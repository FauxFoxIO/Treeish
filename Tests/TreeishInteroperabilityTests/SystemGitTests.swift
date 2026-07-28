import Foundation
import Testing
@testable import Treeish

@Test(arguments: [false, true])
func treeishReadsLooseAndPackedAlternateObjectDatabases(
    packed: Bool
) async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    let shared = parent.appendingPathComponent("shared")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    func git(_ directory: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
    #expect(try git(source, ["init"]).0 == 0)
    try Data("alternate\n".utf8).write(
        to: source.appendingPathComponent("file.txt")
    )
    #expect(try git(source, ["add", "file.txt"]).0 == 0)
    #expect(try git(source, ["commit", "-m", "alternate"]).0 == 0)
    let expected = try ObjectID(
        hex: git(source, ["rev-parse", "HEAD"]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    if packed {
        #expect(try git(source, ["repack", "-ad"]).0 == 0)
        #expect(try git(source, ["prune-packed"]).0 == 0)
    }
    let clone = Process()
    clone.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    clone.arguments = ["clone", "--shared", source.path, shared.path]
    try clone.run()
    clone.waitUntilExit()
    #expect(clone.terminationStatus == 0)

    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.open(
        try await Treeish.discover(
            in: root,
            from: try GitPath("shared")
        ),
        roots: [root]
    )
    #expect(await repository.capabilities().usesAlternates)
    #expect(try await repository.snapshot().headObjectID == expected)
    #expect(try await repository.status().value().isClean)
    #expect(
        try await repository.log(from: [expected], limit: 1)
            .value().first?.objectID == expected
    )
}

@Test func treeishHonorsSystemGitShallowBoundaries() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    let shallow = parent.appendingPathComponent("shallow")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    func git(_ directory: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
    #expect(try git(source, ["init"]).0 == 0)
    for number in 1...4 {
        try Data("\(number)\n".utf8).write(
            to: source.appendingPathComponent("value.txt")
        )
        #expect(try git(source, ["add", "value.txt"]).0 == 0)
        #expect(try git(source, ["commit", "-m", "commit \(number)"]).0 == 0)
    }
    let clone = Process()
    clone.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    clone.arguments = [
        "clone", "--depth=2", source.absoluteString, shallow.path,
    ]
    try clone.run()
    clone.waitUntilExit()
    #expect(clone.terminationStatus == 0)
    let head = try ObjectID(
        hex: git(shallow, ["rev-parse", "HEAD"]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let boundary = try ObjectID(
        hex: git(shallow, ["rev-parse", "HEAD~1"]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )

    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.open(
        try await Treeish.discover(
            in: root,
            from: try GitPath("shallow")
        ),
        roots: [root]
    )
    #expect(await repository.capabilities().isShallow)
    let log = try await repository.log(from: [head]).value()
    #expect(log.map(\.objectID) == [head, boundary])
    #expect(log.last?.parents.isEmpty == true)
}

@Test func treeishAppliesSystemGitReplacementReferences() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    func git(
        _ arguments: [String],
        input: String? = nil
    ) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if let input {
            let standardInput = Pipe()
            process.standardInput = standardInput
            try process.run()
            standardInput.fileHandleForWriting.write(Data(input.utf8))
            try standardInput.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
    #expect(try git(["init"]).0 == 0)
    try Data("replacement\n".utf8).write(
        to: directory.appendingPathComponent("file.txt")
    )
    #expect(try git(["add", "file.txt"]).0 == 0)
    #expect(try git(["commit", "-m", "original message"]).0 == 0)
    let original = try ObjectID(
        hex: git(["rev-parse", "HEAD"]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let tree = try git(["rev-parse", "HEAD^{tree}"]).1
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let replacementResult = try git(
        ["commit-tree", tree],
        input: "replacement message\n"
    )
    #expect(replacementResult.0 == 0)
    let replacement = try ObjectID(
        hex: replacementResult.1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    #expect(
        try git(["replace", original.description, replacement.description]).0
            == 0
    )

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    let log = try await repository.log(from: [original], limit: 1).value()
    #expect(log.first?.objectID == original)
    #expect(log.first?.parents.isEmpty == true)
    #expect(String(decoding: log.first?.message ?? [], as: UTF8.self)
        == "replacement message\n")
    let object = try await repository.readObject(original).value()
    #expect(
        String(decoding: object.payload, as: UTF8.self)
            .contains("replacement message")
    )

    let updatedReplacementResult = try git(
        ["commit-tree", tree],
        input: "updated replacement message\n"
    )
    #expect(updatedReplacementResult.0 == 0)
    let updatedReplacement = try ObjectID(
        hex: updatedReplacementResult.1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let replacementReference = try RefName(
        "refs/replace/\(original.description)"
    )
    _ = try await repository.updateReference(
        replacementReference,
        to: updatedReplacement,
        expected: replacement
    ).value()
    let updatedObject = try await repository.readObject(original).value()
    #expect(
        String(decoding: updatedObject.payload, as: UTF8.self)
            .contains("updated replacement message")
    )

    _ = try await repository.deleteReference(
        replacementReference,
        expected: updatedReplacement
    ).value()
    let restoredObject = try await repository.readObject(original).value()
    #expect(
        String(decoding: restoredObject.payload, as: UTF8.self)
            .contains("original message")
    )
}

@Test(arguments: [false, true])
func treeishUsesSystemGitMultiPackIndexForObjectLookup(
    incremental: Bool
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    try git(["init"])
    for number in 1...2 {
        try Data("\(number)\n".utf8).write(
            to: directory.appendingPathComponent("value.txt")
        )
        try git(["add", "value.txt"])
        try git(["commit", "-m", "commit \(number)"])
        try git(["repack", "-d"])
        if incremental {
            try git(["multi-pack-index", "write", "--incremental"])
        }
    }
    if !incremental {
        try git(["multi-pack-index", "write"])
    }
    let packDirectory = directory.appendingPathComponent(".git/objects/pack")
    for file in try FileManager.default.contentsOfDirectory(
        at: packDirectory,
        includingPropertiesForKeys: nil
    ) where file.pathExtension == "idx" {
        try FileManager.default.removeItem(at: file)
    }

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    #expect(await repository.capabilities().hasMultiPackIndex)
    let head = try #require(try await repository.snapshot().headObjectID)
    #expect(try await repository.log(from: [head]).value().count == 2)
    #expect(try await repository.status().value().isClean)
}

@Test func treeishRecognizesPromisorRepositoryConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    try git(["init"])
    try Data("promisor\n".utf8).write(
        to: directory.appendingPathComponent("file.txt")
    )
    try git(["add", "file.txt"])
    try git(["commit", "-m", "promisor"])
    try git(["config", "core.repositoryformatversion", "1"])
    try git(["config", "extensions.partialClone", "origin"])
    try git(["config", "remote.origin.url", "https://example.com/repository.git"])
    try git(["config", "remote.origin.promisor", "true"])
    try git(["config", "remote.origin.partialclonefilter", "blob:none"])
    try git([
        "config", "remote.cache.url",
        "https://cache.example.test/repository.git",
    ])
    try git(["config", "remote.cache.promisor", "true"])

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    let capabilities = await repository.capabilities()
    #expect(capabilities.promisorRemotes == ["cache", "origin"])
    #expect(capabilities.access == .readWrite)
    #expect(try await repository.status().value().isClean)
}

@Test func treeishReadsSystemGitReftableStack() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    func git(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    #expect(try git(["init", "--ref-format=reftable"]).0 == 0)
    try Data("reftable\n".utf8).write(
        to: directory.appendingPathComponent("file.txt")
    )
    #expect(try git(["add", "file.txt"]).0 == 0)
    #expect(try git(["commit", "-m", "initial"]).0 == 0)
    #expect(try git(["branch", "side"]).0 == 0)
    #expect(try git(["tag", "lightweight"]).0 == 0)
    #expect(try git(["tag", "-a", "annotated", "-m", "tag"]).0 == 0)
    #expect(try git(["branch", "-D", "side"]).0 == 0)

    let expectedHead = try ObjectID(
        hex: git(["rev-parse", "HEAD"]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    let capabilities = await repository.capabilities()
    #expect(capabilities.refStorage == .reftable)
    #expect(capabilities.access == .readWrite)
    let snapshot = try await repository.snapshot()
    #expect(snapshot.headReference == (try RefName("refs/heads/main")))
    #expect(snapshot.headObjectID == expectedHead)
    let references = try await repository.listReferences().value()
    #expect(references.map(\.name.description) == [
        "refs/heads/main",
        "refs/tags/annotated",
        "refs/tags/lightweight",
    ])
    #expect(references.allSatisfy { $0.objectID.algorithm == .sha1 })
}

@Test(arguments: ObjectHashAlgorithm.allCases)
func systemGitReadsAndMutatesTreeishReftableRepository(
    objectFormat: ObjectHashAlgorithm
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("reftable.txt")
    try Data("treeish\n".utf8).write(to: file)
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(
        in: root,
        options: RepositoryInitialization(
            objectFormat: objectFormat,
            refStorage: .reftable
        )
    )
    #expect(await repository.capabilities().access == .readWrite)
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("reftable.txt")])
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
            message: Array("treeish reftable\n".utf8)
        )
    ).value().objectID
    _ = try await repository.createBranch(
        named: "temporary",
        at: commit,
        reflog: ReflogMetadata(
            signature: signature,
            message: "branch: Created from main"
        )
    ).value()
    _ = try await repository.createTag(
        TagRequest(name: "treeish-tag", target: commit)
    ).value()
    _ = try await repository.deleteReference(
        try RefName("refs/heads/temporary"),
        expected: commit
    ).value()

    func git(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
    #expect(try git(["fsck", "--strict"]).0 == 0)
    #expect(try git(["rev-parse", "HEAD"]).1 == "\(commit)\n")
    #expect(
        try git(["reflog", "show", "--format=%gs", "HEAD"]).1
            == "commit: treeish reftable\n"
    )
    #expect(try await repository.headReflog().first?.current == commit)
    #expect(try git(["rev-parse", "treeish-tag"]).1 == "\(commit)\n")
    #expect(try git(["show-ref", "--verify", "refs/heads/temporary"]).0 != 0)

    try Data("system git\n".utf8).write(to: file)
    #expect(try git(["add", "reftable.txt"]).0 == 0)
    #expect(try git(["commit", "-m", "system mutation"]).0 == 0)
    let reopened = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    #expect(try await reopened.status().value().isClean)
    #expect(try await reopened.snapshot().headObjectID != commit)
}

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

@Test func systemGitReadsAndMutatesTreeishSHA256Repository() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("sha256.txt")
    try Data("treeish\n".utf8).write(to: file)

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(
        in: root,
        options: RepositoryInitialization(objectFormat: .sha256)
    )
    #expect(await repository.capabilities().objectFormat == .sha256)
    #expect(await repository.capabilities().access == .readWrite)
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("sha256.txt")])
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
            message: Array("sha256 initial\n".utf8)
        )
    ).value()
    #expect(commit.objectID.algorithm == .sha256)
    #expect(commit.objectID.description.count == 64)

    func git(_ arguments: [String]) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            output.fileHandleForReading.readDataToEndOfFile()
        )
    }

    let format = try git(["rev-parse", "--show-object-format"])
    #expect(format.0 == 0)
    #expect(String(decoding: format.1, as: UTF8.self) == "sha256\n")
    #expect(try git(["fsck", "--strict"]).0 == 0)

    try Data("system git\n".utf8).write(to: file)
    #expect(try git(["add", "sha256.txt"]).0 == 0)
    let environment = [
        "GIT_AUTHOR_NAME": "System Git",
        "GIT_AUTHOR_EMAIL": "git@example.com",
        "GIT_COMMITTER_NAME": "System Git",
        "GIT_COMMITTER_EMAIL": "git@example.com",
    ]
    let commitProcess = Process()
    commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    commitProcess.arguments = [
        "-C", directory.path, "commit", "-m", "system git mutation",
    ]
    commitProcess.environment = ProcessInfo.processInfo.environment.merging(
        environment,
        uniquingKeysWith: { _, new in new }
    )
    try commitProcess.run()
    commitProcess.waitUntilExit()
    #expect(commitProcess.terminationStatus == 0)

    let reopened = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    #expect(try await reopened.snapshot().headObjectID?.algorithm == .sha256)
    #expect(try await reopened.status().value().isClean)
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

@Test(arguments: [RefStorageFormat.files, .reftable])
func systemGitRecognizesTreeishLinkedWorktree(
    refStorage: RefStorageFormat
) async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let main = parent.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try Data("linked\n".utf8).write(to: main.appendingPathComponent("file.txt"))
    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.initialize(
        in: root,
        at: try GitPath("main"),
        options: RepositoryInitialization(refStorage: refStorage)
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
    try Data("worker-only.tmp\n".utf8).write(
        to: main.appendingPathComponent(".git/info/exclude")
    )
    try Data("ignored\n".utf8).write(
        to: parent.appendingPathComponent("worker/worker-only.tmp")
    )
    let linkedRepository = try await Treeish.open(
        try await Treeish.discover(
            in: root,
            from: try GitPath("worker")
        ),
        roots: [root]
    )
    let linkedStatus = try await linkedRepository.status().value()
    #expect(
        !linkedStatus.entries.contains {
            $0.path == (try? GitPath("worker-only.tmp"))
        }
    )
    try Data("file.txt filter=crypt\n".utf8).write(
        to: main.appendingPathComponent(".git/info/attributes")
    )
    try Data("changed\n".utf8).write(
        to: parent.appendingPathComponent("worker/file.txt")
    )
    await #expect(throws: TreeishError.unsupportedContentConversion(
        try GitPath("file.txt"),
        "filter=crypt"
    )) {
        _ = try await linkedRepository.stage(
            StageRequest(pathspecs: [try GitPathspec("file.txt")])
        ).value()
    }
    try Data("linked\n".utf8).write(
        to: parent.appendingPathComponent("worker/file.txt")
    )
    try FileManager.default.removeItem(
        at: parent.appendingPathComponent("worker/worker-only.tmp")
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
    #expect(
        try await repository.headReflog().first?.message
            .hasPrefix("merge \(theirs): Merge made by Treeish") == true
    )
    #expect(
        try await repository.reflog(
            for: try RefName("refs/heads/main")
        ).first?.message.hasPrefix("merge \(theirs):") == true
    )
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

@Test(arguments: [false, true])
func treeishReadsSystemGitReflogsAndRevisionSelectors(
    reftable: Bool
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    func git(_ arguments: [String], date: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        if let date {
            environment["GIT_AUTHOR_DATE"] = date
            environment["GIT_COMMITTER_DATE"] = date
        }
        process.environment = environment
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
            throw TreeishError.recoveryRequired(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    _ = try git(reftable ? ["init", "--ref-format=reftable"] : ["init"])
    try Data("first\n".utf8).write(
        to: directory.appendingPathComponent("file.txt")
    )
    _ = try git(["add", "file.txt"])
    _ = try git(["commit", "-m", "first"], date: "2024-01-01T12:00:00+00:00")
    let first = try ObjectID(hex: git(["rev-parse", "HEAD"]))
    try Data("second\n".utf8).write(
        to: directory.appendingPathComponent("file.txt")
    )
    _ = try git(["commit", "-am", "second"], date: "2024-01-02T12:00:00+00:00")
    let second = try ObjectID(hex: git(["rev-parse", "HEAD"]))

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    let branch = try git(["symbolic-ref", "--short", "HEAD"])
    let branchName = try RefName("refs/heads/\(branch)")
    let entries = try await repository.reflog(for: branchName)
    #expect(entries.count == 2)
    #expect(entries[0].current == second)
    #expect(entries[1].current == first)
    #expect(entries[0].message == "commit: second")
    #expect(entries[1].committer.email == "git@example.com")
    #expect(try await repository.resolveRevision("\(branch)@{1}") == first)
    #expect(
        try await repository.resolveRevision(
            "\(branch)@{2024-01-01T18:00:00Z}"
        ) == first
    )
    #expect(try await repository.headReflog().first?.current == second)
}

@Test(arguments: [RefStorageFormat.files, .reftable])
func checkoutMovesOnlyHeadAndResetLogsResolvedHead(
    refStorage: RefStorageFormat
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(
        in: root,
        options: RepositoryInitialization(refStorage: refStorage)
    )
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let file = directory.appendingPathComponent("value.txt")

    func commit(_ value: String, parents: [ObjectID]) async throws -> ObjectID {
        try Data(value.utf8).write(to: file)
        _ = try await repository.stage(
            StageRequest(pathspecs: [try GitPathspec("value.txt")])
        ).value()
        return try await repository.commit(
            CommitRequest(
                tree: try await repository.writeIndexTree().value(),
                parents: parents,
                author: signature,
                committer: signature,
                message: Array("\(value)\n".utf8)
            )
        ).value().objectID
    }

    let base = try await commit("base", parents: [])
    let feature = try RefName("refs/heads/feature")
    _ = try await repository.createBranch(
        named: "feature",
        at: base,
        reflog: ReflogMetadata(
            signature: signature,
            message: "branch: Created from main"
        )
    ).value()
    let mainTip = try await commit("main", parents: [base])
    await #expect(throws: TreeishError.referenceChanged) {
        _ = try await repository.checkout(
            CheckoutRequest(commit: mainTip, reference: feature)
        ).value()
    }
    #expect(try await repository.resolveReference(feature) == base)
    let checkoutLog = ReflogMetadata(
        signature: signature,
        message: "checkout: moving from main to feature"
    )
    _ = try await repository.checkout(
        CheckoutRequest(
            commit: base,
            reference: feature,
            reflog: checkoutLog
        )
    ).value()

    #expect(
        try await repository.resolveReference(
            try RefName("refs/heads/main")
        ) == mainTip
    )
    #expect(try await repository.resolveReference(feature) == base)
    #expect(try await repository.snapshot().headReference == feature)
    #expect(try await repository.headReflog().first?.message == checkoutLog.message)
    #expect(
        try await repository.reflog(for: feature).contains {
            $0.message == checkoutLog.message
        } == false
    )

    let resetLog = ReflogMetadata(
        signature: signature,
        message: "reset: moving to \(mainTip)"
    )
    _ = try await repository.reset(
        ResetRequest(commit: mainTip, mode: .hard, reflog: resetLog)
    ).value()
    #expect(try await repository.resolveReference(feature) == mainTip)
    #expect(try await repository.headReflog().first?.message == resetLog.message)
    #expect(try await repository.reflog(for: feature).first?.message == resetLog.message)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "symbolic-ref", "HEAD"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(
        String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ) == "refs/heads/feature\n"
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
    try Data(
        "*.txt text eol=lf\ncrlf.txt text eol=crlf\nsecret.bin filter=crypt\n".utf8
    ).write(
        to: directory.appendingPathComponent(".gitattributes")
    )
    try Data("drop\n".utf8).write(to: directory.appendingPathComponent("build/drop.txt"))
    try Data("keep\r\n".utf8).write(to: directory.appendingPathComponent("build/keep.txt"))
    try Data("line one\r\nline two\r\n".utf8).write(
        to: directory.appendingPathComponent("content.txt")
    )
    try Data("preserve\r\n".utf8).write(
        to: directory.appendingPathComponent("override.txt")
    )
    try Data("checkout\r\n".utf8).write(
        to: directory.appendingPathComponent("crlf.txt")
    )
    try Data("ignored by info\n".utf8).write(
        to: directory.appendingPathComponent("info-only.tmp")
    )
    try Data("secret".utf8).write(to: directory.appendingPathComponent("secret.bin"))
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    try Data("info-only.tmp\n".utf8).write(
        to: directory.appendingPathComponent(".git/info/exclude")
    )
    try Data("override.txt -text !eol\n".utf8).write(
        to: directory.appendingPathComponent(".git/info/attributes")
    )
    let status = try await repository.status().value()
    #expect(!status.entries.contains { $0.path == (try? GitPath("build/drop.txt")) })
    #expect(!status.entries.contains { $0.path == (try? GitPath("info-only.tmp")) })
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
            try GitPathspec("crlf.txt"),
            try GitPathspec("override.txt"),
        ])
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
    let override = Process()
    override.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    override.arguments = ["-C", directory.path, "show", "HEAD:override.txt"]
    let overrideOutput = Pipe()
    override.standardOutput = overrideOutput
    try override.run()
    override.waitUntilExit()
    #expect(override.terminationStatus == 0)
    #expect(
        overrideOutput.fileHandleForReading.readDataToEndOfFile() ==
            Data("preserve\r\n".utf8)
    )
    try FileManager.default.removeItem(
        at: directory.appendingPathComponent("crlf.txt")
    )
    _ = try await repository.checkout(
        CheckoutRequest(
            commit: commit.objectID,
            reference: try RefName("refs/heads/main")
        )
    ).value()
    #expect(
        try Data(contentsOf: directory.appendingPathComponent("crlf.txt"))
            == Data("checkout\r\n".utf8)
    )
    #expect(try await repository.status().value().entries == [
        StatusEntry(
            path: try GitPath("secret.bin"),
            worktreeChange: .untracked
        ),
    ])
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
    #expect(
        try await repository.headReflog().first?.message
            .hasPrefix("cherry-pick:") == true
    )
    #expect(
        try await repository.reflog(
            for: try RefName("refs/heads/main")
        ).first?.message.hasPrefix("cherry-pick:") == true
    )

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

@Test func treeishPreservesSystemGitSparseCheckout() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    func git(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    #expect(try git(["init"]).0 == 0)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("included"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("excluded"),
        withIntermediateDirectories: true
    )
    try Data("root\n".utf8).write(
        to: directory.appendingPathComponent("root.txt")
    )
    try Data("included\n".utf8).write(
        to: directory.appendingPathComponent("included/file.txt")
    )
    try Data("excluded\n".utf8).write(
        to: directory.appendingPathComponent("excluded/file.txt")
    )
    #expect(try git(["add", "."]).0 == 0)
    #expect(try git(["commit", "-m", "sparse fixture"]).0 == 0)
    let head = try ObjectID(
        hex: git(["rev-parse", "HEAD"]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    #expect(
        try git([
            "sparse-checkout", "set", "--sparse-index", "included",
        ]).0 == 0
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("excluded/file.txt").path
        )
    )

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )
    #expect(await repository.capabilities().access == .readWrite)
    #expect(await repository.capabilities().index.canRead)
    #expect(try await repository.status().value().isClean)
    let result = try await repository.checkout(
        CheckoutRequest(
            commit: head,
            reference: try RefName("refs/heads/main")
        )
    ).value()
    #expect(result.pathsWritten == 2)
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("excluded/file.txt").path
        )
    )
    await #expect(
        throws: TreeishError.pathOutsideSparseCheckout(
            try GitPath("excluded/file.txt")
        )
    ) {
        _ = try await repository.stage(
            StageRequest(
                pathspecs: [try GitPathspec("excluded/file.txt")]
            )
        ).value()
    }
    #expect(try git(["status", "--porcelain=v1"]).1.isEmpty)
    let files = try git(["ls-files", "-t"]).1
    #expect(files.contains("S excluded/file.txt"))
    #expect(files.contains("H included/file.txt"))
}

@Test func treeishPreservesSHA256IndexAcrossResetAndCherryPick() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(
        in: root,
        options: RepositoryInitialization(objectFormat: .sha256)
    )
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    func commit(
        path: String,
        text: String,
        parents: [ObjectID],
        expected: ObjectID?
    ) async throws -> ObjectID {
        try Data(text.utf8).write(
            to: directory.appendingPathComponent(path)
        )
        _ = try await repository.stage(
            StageRequest(pathspecs: [try GitPathspec(path)])
        ).value()
        return try await repository.commit(
            CommitRequest(
                tree: try await repository.writeIndexTree().value(),
                parents: parents,
                expectedHead: expected,
                author: signature,
                committer: signature,
                message: Array("\(path)\n".utf8)
            )
        ).value().objectID
    }
    func git(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    let base = try await commit(
        path: "base.txt",
        text: "base\n",
        parents: [],
        expected: nil
    )
    let second = try await commit(
        path: "base.txt",
        text: "second\n",
        parents: [base],
        expected: base
    )
    _ = try await repository.reset(
        ResetRequest(commit: base, mode: .mixed)
    ).value()
    #expect(try git(["ls-files", "--stage"]).0 == 0)
    _ = try await repository.reset(
        ResetRequest(commit: second, mode: .hard)
    ).value()
    #expect(try git(["status", "--porcelain=v1"]).1.isEmpty)

    _ = try await repository.createBranch(
        named: "feature",
        at: second
    ).value()
    let main = try await commit(
        path: "main.txt",
        text: "main\n",
        parents: [second],
        expected: second
    )
    _ = try await repository.checkout(
        CheckoutRequest(
            commit: second,
            reference: try RefName("refs/heads/feature")
        )
    ).value()
    let picked = try await commit(
        path: "feature.txt",
        text: "feature\n",
        parents: [second],
        expected: second
    )
    _ = try await repository.checkout(
        CheckoutRequest(
            commit: main,
            reference: try RefName("refs/heads/main")
        )
    ).value()
    guard case .committed(let result) = try await repository.cherryPick(
        CherryPickRequest(
            commit: picked,
            author: signature,
            committer: signature
        )
    ).value() else {
        Issue.record("expected SHA-256 cherry-pick commit")
        return
    }
    #expect(result.algorithm == .sha256)
    guard case .merged(let merged) = try await repository.merge(
        MergeRequest(
            other: picked,
            author: signature,
            committer: signature,
            message: Array("merge feature\n".utf8)
        )
    ).value() else {
        Issue.record("expected SHA-256 merge commit")
        return
    }
    #expect(merged.algorithm == .sha256)
    #expect(try git(["status", "--porcelain=v1"]).1.isEmpty)
    #expect(try git(["fsck", "--strict"]).0 == 0)
}

@Test func treeishReportsSystemGitSubmoduleStates() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let child = parent.appendingPathComponent("child-source")
    let superproject = parent.appendingPathComponent("superproject")
    try FileManager.default.createDirectory(
        at: child,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: superproject,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    func git(_ directory: URL, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "System Git",
            "GIT_AUTHOR_EMAIL": "git@example.com",
            "GIT_COMMITTER_NAME": "System Git",
            "GIT_COMMITTER_EMAIL": "git@example.com",
        ], uniquingKeysWith: { _, new in new })
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    #expect(try git(child, ["init"]) == 0)
    try Data("child\n".utf8).write(
        to: child.appendingPathComponent("child.txt")
    )
    #expect(try git(child, ["add", "child.txt"]) == 0)
    #expect(try git(child, ["commit", "-m", "child"]) == 0)
    #expect(try git(superproject, ["init"]) == 0)
    #expect(try git(superproject, [
        "-c", "protocol.file.allow=always",
        "submodule", "add", child.path, "modules/child",
    ]) == 0)
    #expect(try git(superproject, ["commit", "-am", "submodule"]) == 0)

    let root = try await TreeishRoot.localDirectory(at: parent)
    let repository = try await Treeish.open(
        try await Treeish.discover(
            in: root,
            from: try GitPath("superproject")
        ),
        roots: [root]
    )
    var statuses = try await repository.submodules().value()
    #expect(statuses.count == 1)
    #expect(statuses.first?.configuration?.name == "modules/child")
    #expect(statuses.first?.path == (try GitPath("modules/child")))
    #expect(statuses.first?.state == .clean)
    #expect(statuses.first?.expectedCommit == statuses.first?.checkedOutCommit)

    let checkout = superproject.appendingPathComponent("modules/child")
    try Data("modified\n".utf8).write(
        to: checkout.appendingPathComponent("child.txt")
    )
    statuses = try await repository.submodules().value()
    #expect(statuses.first?.state == .modified)
    #expect(
        try await repository.status().value().entries.contains {
            $0.path == (try? GitPath("modules/child")) &&
                $0.worktreeChange == .modified
        }
    )

    #expect(try git(checkout, ["add", "child.txt"]) == 0)
    #expect(try git(checkout, ["commit", "-m", "different"]) == 0)
    statuses = try await repository.submodules().value()
    #expect(statuses.first?.state == .differentCommit)
    #expect(
        try await repository.status().value().entries.contains {
            $0.path == (try? GitPath("modules/child")) &&
            $0.worktreeChange == .modified
        }
    )
    statuses = try await repository.updateSubmodules(
        SubmoduleUpdateRequest(fetch: false)
    ).value()
    #expect(statuses.first?.state == .clean)
    #expect(statuses.first?.expectedCommit == statuses.first?.checkedOutCommit)

    try Data("dirty again\n".utf8).write(
        to: checkout.appendingPathComponent("child.txt")
    )
    await #expect(throws: TreeishError.recoveryRequired(
        "submodule modules/child has local changes"
    )) {
        _ = try await repository.updateSubmodules(
            SubmoduleUpdateRequest(fetch: false)
        ).value()
    }
    statuses = try await repository.updateSubmodules(
        SubmoduleUpdateRequest(
            fetch: false,
            force: true
        )
    ).value()
    #expect(statuses.first?.state == .clean)
    statuses = try await repository.updateSubmodules(
        SubmoduleUpdateRequest(
            fetch: false,
            recursive: true,
            maximumDepth: 1
        )
    ).value()
    #expect(statuses.first?.state == .clean)

    try FileManager.default.removeItem(
        at: checkout.appendingPathComponent(".git")
    )
    statuses = try await repository.submodules().value()
    #expect(statuses.first?.state == .uninitialized)
    #expect(try await repository.status().value().isClean)
}
