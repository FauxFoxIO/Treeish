import Foundation
import Testing
@testable import Treeish

@Test func pathsRejectTraversal() throws {
    #expect(throws: TreeishError.self) {
        try GitPath("../outside")
    }
    #expect(try GitPath("Sources/File.swift").displayString == "Sources/File.swift")
}

@Test func pathspecMagicSelectsIncludesAndExcludesDeterministically() throws {
    let paths = try [
        GitPath("Sources/App.swift"),
        GitPath("Sources/AppTests.swift"),
        GitPath("README.md"),
        GitPath("nested/README.MD"),
    ]
    let selected = GitPathspec.select(
        paths,
        using: [
            try GitPathspec(":(glob,top)Sources/**/*.swift"),
            try GitPathspec(":(exclude)Sources/*Tests.swift"),
        ]
    )
    #expect(selected == [try GitPath("Sources/App.swift")])
    #expect(
        GitPathspec.select(
            paths,
            using: [try GitPathspec(":(icase)readme.md")]
        ) == [
            try GitPath("README.md"),
            try GitPath("nested/README.MD"),
        ]
    )
    #expect(throws: TreeishError.invalidPath) {
        _ = try GitPathspec(":(attr:text)*.txt")
    }
    #expect(throws: TreeishError.invalidPath) {
        _ = try GitPathspec("../outside")
    }
}

@Test func initializesAndReopensRepository() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let snapshot = try await repository.snapshot()

    #expect(snapshot.headReference?.description == "refs/heads/main")
    #expect(snapshot.headObjectID == nil)
    #expect(await repository.capabilities().access == .readWrite)
}

@Test func configPreservesUnrelatedContentAndLoadsBoundedIncludes() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    let source = """
    # retained comment
    [core]
    \trepositoryFormatVersion = 0
    [include]
    \tpath = extra.conf
    [remote \"origin\"]
    \turl = \"https://example.com/a\\tb.git\"

    """
    try root.directory.writeAtomically(Array(source.utf8), to: ["config"])
    try root.directory.writeAtomically(
        Array("[extensions]\n\tobjectFormat = sha1\n".utf8),
        to: ["extra.conf"]
    )
    let config = try GitConfiguration.load(from: root.directory)
    #expect(config.integer(section: "core", key: "repositoryformatversion") == 0)
    #expect(config.value(section: "extensions", key: "objectformat") == "sha1")
    #expect(config.value(section: "remote", subsection: "origin", key: "url") == "https://example.com/a\tb.git")
    let replaced = try config.replacing(
        section: "core",
        key: "repositoryformatversion",
        value: "1"
    )
    let replacedText = String(decoding: replaced, as: UTF8.self)
    #expect(replacedText.contains("# retained comment"))
    #expect(replacedText.contains("[remote \"origin\"]"))
    #expect(try GitConfiguration(bytes: replaced).integer(section: "core", key: "repositoryformatversion") == 1)

    try root.directory.writeAtomically(
        Array("[include]\n\tpath = config\n".utf8),
        to: ["extra.conf"]
    )
    #expect(throws: GitConfigurationError.includeCycle) {
        try GitConfiguration.load(from: root.directory)
    }
}

@Test func preparedWorktreeTransactionRollsBackWhenRepositoryReopens() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    try Data("before\n".utf8).write(to: file)
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("file.txt")])
    ).value()
    let originalIndex = try root.directory.read(
        [".git", "index"],
        limit: 1024 * 1024
    )
    let gitDirectory = try root.directory.childDirectory([".git"])
    _ = try WorktreeTransaction.begin(
        paths: [try GitPath("file.txt")],
        gitDirectory: gitDirectory,
        worktree: root.directory,
        maximumBytes: 1024 * 1024
    )
    try Data("interrupted\n".utf8).write(to: file)
    try gitDirectory.writeAtomically([0x00], to: ["index"])

    let location = try await Treeish.discover(in: root)
    _ = try await Treeish.open(location, roots: [root])

    #expect(try Data(contentsOf: file) == Data("before\n".utf8))
    #expect(
        try root.directory.read([".git", "index"], limit: 1024 * 1024)
            == originalIndex
    )
    #expect(!(try gitDirectory.exists(["treeish", "worktree-transaction"])))
}
