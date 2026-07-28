import Foundation
import Testing
@testable import Treeish
import TreeishCore
import TreeishHTTP
import TreeishObjects
import TreeishPacks
import TreeishProtocol

private actor ScriptedSmartHTTPTransport: SmartHTTPTransport {
    private var responses: [SmartHTTPTransportResponse]
    private(set) var requests: [SmartHTTPRequest] = []

    init(responses: [SmartHTTPTransportResponse]) { self.responses = responses }

    func execute(_ request: SmartHTTPRequest) async throws -> SmartHTTPTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw SmartHTTPError.invalidResponse }
        return responses.removeFirst()
    }
}

private struct GitHubTokenCredentials: GitCredentialProvider {
    let token: String

    func credential(
        for challenge: GitAuthenticationChallenge
    ) async throws -> GitCredentialDisposition {
        guard challenge.host == "example.test" else {
            return .reject
        }
        return .use(.githubToken(token))
    }
}

private actor ScriptedSSHGitSession: SSHGitSession {
    private let advertised: [UInt8]
    private let response: [UInt8]
    private(set) var requests: [[UInt8]] = []

    init(advertised: [UInt8], response: [UInt8]) {
        self.advertised = advertised
        self.response = response
    }

    func advertisement() async throws -> [UInt8] {
        advertised
    }

    func exchange(_ request: [UInt8]) async throws -> [UInt8] {
        requests.append(request)
        return response
    }
}

private actor ScriptedSSHGitTransport: SSHGitTransport {
    private let session: ScriptedSSHGitSession
    private(set) var requests: [SSHGitSessionRequest] = []

    init(session: ScriptedSSHGitSession) {
        self.session = session
    }

    func open(
        _ request: SSHGitSessionRequest
    ) async throws -> any SSHGitSession {
        requests.append(request)
        return session
    }
}

@Test func remoteURLsAndGitHubTokensUseGitTransportConventions() throws {
    let scp = try RemoteURL("git@github.com:FauxFoxIO/Treeish.git")
    #expect(scp.transport == .ssh)
    #expect(scp.sshEndpoint == SSHRemoteEndpoint(
        host: "github.com",
        port: 22,
        username: "git",
        repositoryPath: "FauxFoxIO/Treeish.git"
    ))

    let explicit = try RemoteURL(
        URL(string: "ssh://source@example.com:2222/team/repository.git")!
    )
    #expect(explicit.sshEndpoint?.port == 2222)
    #expect(explicit.sshEndpoint?.username == "source")

    let credential = GitCredential.githubToken("secret")
    let expected = Data("x-access-token:secret".utf8).base64EncodedString()
    #expect(credential.authorizationHeader == "Basic \(expected)")
    #expect(credential.description == "<redacted-git-credential>")
}

@Test func fetchRefspecMapsWildcardsAndNegativeSelections() throws {
    let mapping = try FetchRefspec(
        "+refs/heads/*:refs/remotes/origin/*"
    )
    #expect(mapping.force)
    #expect(mapping.matches(Array("refs/heads/topic".utf8)))
    #expect(
        try mapping.localReference(
            for: Array("refs/heads/topic".utf8)
        ) == RefName("refs/remotes/origin/topic")
    )
    #expect(
        mapping.remoteReference(
            for: Array("refs/remotes/origin/topic".utf8)
        ) == Array("refs/heads/topic".utf8)
    )
    let exclusion = try FetchRefspec("^refs/heads/private/*")
    #expect(exclusion.negative)
    #expect(exclusion.matches(Array("refs/heads/private/secret".utf8)))
    #expect(!exclusion.matches(Array("refs/heads/public".utf8)))
}

@Test func cloneSupportsEmptyProtocolV2Repository() async throws {
    let advertisement =
        try PacketLineEncoder.encode(.data(Array("version 2\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("ls-refs=unborn\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("fetch=wait-for-done\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("object-format=sha1\n".utf8)))
        + PacketLineEncoder.encode(.flush)
    let emptyReferences = try PacketLineEncoder.encode(.flush)
    let remote = try RemoteURL(
        URL(string: "https://example.test/empty.git")!
    )
    let transport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-upload-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: emptyReferences,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("empty"),
        withIntermediateDirectories: true
    )
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.clone(
        try CloneRequest(
            remote: remote,
            destination: try GitPath("empty")
        ),
        in: root,
        services: RepositoryServices(httpTransport: transport)
    )
    #expect(try await repository.listReferences().value().isEmpty)
    let configuration = String(
        decoding: try root.directory.read(
            ["empty", ".git", "config"],
            limit: 1024 * 1024
        ),
        as: UTF8.self
    )
    #expect(configuration.contains("[remote \"origin\"]"))
    #expect(
        configuration.contains(
            "url = \"https://example.test/empty.git\""
        )
    )
    #expect(await transport.requests.count == 2)
}

@Test func mirrorCloneCreatesExactLinkedWorktreeWithoutSystemGit() async throws {
    let blob = GitObject(
        type: .blob,
        payload: Array("mirror\n".utf8)
    )
    let blobID = SHA1.hash(blob.canonicalBytes)
    let tree = GitObjectEncoder.tree(entries: [
        try GitTreeEntry(
            mode: .regular,
            name: Array("README.md".utf8),
            objectID: blobID
        ),
    ])
    let treeID = SHA1.hash(tree.canonicalBytes)
    let signature = GitSignature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = GitObjectEncoder.commit(
        treeHex: treeID.map { String(format: "%02x", $0) }.joined(),
        parentHexes: [],
        author: signature,
        committer: signature,
        message: Array("mirror\n".utf8)
    )
    let commitID = SHA1.hash(commit.canonicalBytes)
    let commitHex = commitID.map {
        String(format: "%02x", $0)
    }.joined()
    let archive = try PackWriter.write([
        try PackObject(identifier: blobID, object: blob),
        try PackObject(identifier: treeID, object: tree),
        try PackObject(identifier: commitID, object: commit),
    ])
    let advertisement =
        try PacketLineEncoder.encode(.data(Array("version 2\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("ls-refs=unborn\n".utf8)))
        + PacketLineEncoder.encode(
            .data(Array("fetch=wait-for-done\n".utf8))
        )
        + PacketLineEncoder.encode(
            .data(Array("object-format=sha1\n".utf8))
        )
        + PacketLineEncoder.encode(.flush)
    let references = try PacketLineEncoder.encode(
        .data(Array(
            "\(commitHex) HEAD symref-target:refs/heads/main\n".utf8
        ))
    ) + PacketLineEncoder.encode(
        .data(Array("\(commitHex) refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(
        .data(Array("\(commitHex) refs/tags/v1\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
    let fetch =
        try PacketLineEncoder.encode(.data(Array("packfile\n".utf8)))
        + PacketLineEncoder.encode(.data([1] + archive.pack))
        + PacketLineEncoder.encode(.flush)
    let remote = try RemoteURL(
        URL(string: "https://example.test/mirror.git")!
    )
    let transport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-upload-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: references,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: fetch,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.clone(
        try CloneRequest(
            remote: remote,
            destination: try GitPath("Repositories/cache.git"),
            mode: .mirror
        ),
        in: root,
        services: RepositoryServices(httpTransport: transport)
    )
    #expect((try await repository.snapshot()).headObjectID == (try ObjectID(
        hex: commitHex
    )))
    #expect(
        try await repository.resolveReference(
            try RefName("refs/tags/v1")
        ) == (try ObjectID(hex: commitHex))
    )
    let fetchKey = try GitConfigurationKey(
        section: "remote",
        subsection: "origin",
        name: "fetch"
    )
    #expect(
        try await repository.configurationValues(for: fetchKey).value()
            == ["+refs/*:refs/*"]
    )
    func git(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
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
    let mirrorPath = directory.appendingPathComponent(
        "Repositories/cache.git"
    ).path
    #expect(
        try git([
            "--git-dir", mirrorPath,
            "rev-parse", "--is-bare-repository",
        ]).1 == "true\n"
    )
    #expect(
        try git(["--git-dir", mirrorPath, "symbolic-ref", "HEAD"]).1
            == "refs/heads/main\n"
    )
    #expect(
        try git(["--git-dir", mirrorPath, "rev-parse", "refs/tags/v1"]).1
            == "\(commitHex)\n"
    )
    let worktree = try await repository.createLinkedWorktree(
        WorktreeRequest(
            destination: try GitPath("Work/job"),
            start: try ObjectID(hex: commitHex)
        )
    ).value()
    #expect(
        try Data(
            contentsOf: directory.appendingPathComponent(
                "Work/job/README.md"
            )
        ) == Data("mirror\n".utf8)
    )
    #expect(
        try git([
            "-C", directory.appendingPathComponent("Work/job").path,
            "rev-parse", "HEAD",
        ]).1 == "\(commitHex)\n"
    )
    #expect(
        try git([
            "-C", directory.appendingPathComponent("Work/job").path,
            "status", "--porcelain",
        ]).1.isEmpty
    )
    #expect(
        try await repository.removeLinkedWorktree(
            identifier: worktree.identifier,
            force: true
        ).value() == (try GitPath("Work/job"))
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Work/job").path
        )
    )
}

@Test func submoduleUpdateInitializesExactGitlinkCommit() async throws {
    let blob = GitObject(
        type: .blob,
        payload: Array("submodule\n".utf8)
    )
    let blobID = SHA1.hash(blob.canonicalBytes)
    let tree = GitObjectEncoder.tree(entries: [
        try GitTreeEntry(
            mode: .regular,
            name: Array("file.txt".utf8),
            objectID: blobID
        ),
    ])
    let treeID = SHA1.hash(tree.canonicalBytes)
    let signature = GitSignature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = GitObjectEncoder.commit(
        treeHex: treeID.map { String(format: "%02x", $0) }.joined(),
        parentHexes: [],
        author: signature,
        committer: signature,
        message: Array("submodule\n".utf8)
    )
    let commitID = SHA1.hash(commit.canonicalBytes)
    let commitHex = commitID.map {
        String(format: "%02x", $0)
    }.joined()
    let archive = try PackWriter.write([
        try PackObject(identifier: blobID, object: blob),
        try PackObject(identifier: treeID, object: tree),
        try PackObject(identifier: commitID, object: commit),
    ])
    let advertisement =
        try PacketLineEncoder.encode(.data(Array("version 2\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("ls-refs=unborn\n".utf8)))
        + PacketLineEncoder.encode(
            .data(Array("fetch=wait-for-done\n".utf8))
        )
        + PacketLineEncoder.encode(
            .data(Array("object-format=sha1\n".utf8))
        )
        + PacketLineEncoder.encode(.flush)
    let references = try PacketLineEncoder.encode(
        .data(Array(
            "\(commitHex) HEAD symref-target:refs/heads/main\n".utf8
        ))
    ) + PacketLineEncoder.encode(
        .data(Array("\(commitHex) refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
    let fetch =
        try PacketLineEncoder.encode(.data(Array("packfile\n".utf8)))
        + PacketLineEncoder.encode(.data([1] + archive.pack))
        + PacketLineEncoder.encode(.flush)
    let remote = try RemoteURL(
        URL(string: "https://example.test/submodule.git")!
    )
    let transport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-upload-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: references,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: fetch,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let superproject = directory.appendingPathComponent("superproject")
    try FileManager.default.createDirectory(
        at: superproject,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    func git(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", superproject.path] + arguments
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
    #expect(try git(["init"]) == 0)
    #expect(try git([
        "remote", "add", "origin",
        "https://example.test/org/superproject.git",
    ]) == 0)
    try Data("""
    [submodule "child"]
        path = modules/child
        url = ../submodule.git

    """.utf8).write(
        to: superproject.appendingPathComponent(".gitmodules")
    )
    #expect(try git(["add", ".gitmodules"]) == 0)
    #expect(try git([
        "update-index", "--add", "--cacheinfo",
        "160000,\(commitHex),modules/child",
    ]) == 0)
    #expect(try git(["commit", "-m", "gitlink"]) == 0)

    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.open(
        try await Treeish.discover(
            in: root,
            from: try GitPath("superproject")
        ),
        roots: [root]
    )
    let result = try await repository.updateSubmodules(
        services: RepositoryServices(httpTransport: transport)
    ).value()
    #expect(result.first?.state == .clean)
    #expect(result.first?.expectedCommit?.description == commitHex)
    #expect(
        try root.directory.read(
            ["superproject", "modules", "child", "file.txt"],
            limit: 1024
        ) == blob.payload
    )
    let superprojectConfiguration = String(
        decoding: try root.directory.read(
            ["superproject", ".git", "config"],
            limit: 1024 * 1024
        ),
        as: UTF8.self
    )
    #expect(superprojectConfiguration.contains("[submodule \"child\"]"))
    #expect(superprojectConfiguration.contains(
        "https://example.test/submodule.git"
    ))
    #expect(await transport.requests.count == 3)

    try FileManager.default.removeItem(
        at: superproject.appendingPathComponent("modules/child")
    )
    let missingCommit = String(repeating: "1", count: 40)
    #expect(try git([
        "update-index", "--cacheinfo",
        "160000,\(missingCommit),modules/child",
    ]) == 0)
    #expect(try git(["commit", "-m", "missing gitlink"]) == 0)
    let rollbackTransport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-upload-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: references,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: fetch,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    await #expect(throws: TreeishError.referenceNotFound) {
        _ = try await repository.updateSubmodules(
            SubmoduleUpdateRequest(fetch: false),
            services: RepositoryServices(
                httpTransport: rollbackTransport
            )
        ).value()
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: superproject
                .appendingPathComponent("modules/child").path
        )
    )
}

@Test func pullFetchesConfiguredUpstreamAndFastForwardsWithoutGit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    try Data("base\n".utf8).write(to: file)
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let signature = Signature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    _ = try await repository.stage(
        StageRequest(pathspecs: [try GitPathspec("file.txt")])
    ).value()
    let base = try await repository.commit(CommitRequest(
        tree: try await repository.writeIndexTree().value(),
        author: signature,
        committer: signature,
        message: Array("base\n".utf8)
    )).value().objectID

    let remote = try RemoteURL(
        URL(string: "https://example.test/pull.git")!
    )
    for (key, value) in [
        ("remote.origin.url", remote.url.absoluteString),
        ("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"),
        ("branch.main.remote", "origin"),
        ("branch.main.merge", "refs/heads/main"),
    ] {
        _ = try await repository.setConfiguration(
            GitConfigurationSetRequest(
                key: try GitConfigurationKey(key),
                value: value
            )
        ).value()
    }
    #expect(
        try await repository.upstreamReference()
            == RefName("refs/remotes/origin/main")
    )

    let remoteBlob = GitObject(
        type: .blob,
        payload: Array("remote\n".utf8)
    )
    let remoteBlobID = SHA1.hash(remoteBlob.canonicalBytes)
    let remoteTree = GitObjectEncoder.tree(entries: [
        try GitTreeEntry(
            mode: .regular,
            name: Array("file.txt".utf8),
            objectID: remoteBlobID
        ),
    ])
    let remoteTreeID = SHA1.hash(remoteTree.canonicalBytes)
    let gitSignature = GitSignature(
        name: signature.name,
        email: signature.email,
        secondsSinceEpoch: signature.secondsSinceEpoch,
        timeZoneOffsetMinutes: signature.timeZoneOffsetMinutes
    )
    let remoteCommit = GitObjectEncoder.commit(
        treeHex: remoteTreeID.map {
            String(format: "%02x", $0)
        }.joined(),
        parentHexes: [base.description],
        author: gitSignature,
        committer: gitSignature,
        message: Array("remote\n".utf8)
    )
    let remoteCommitID = SHA1.hash(remoteCommit.canonicalBytes)
    let remoteHex = remoteCommitID.map {
        String(format: "%02x", $0)
    }.joined()
    let archive = try PackWriter.write([
        try PackObject(identifier: remoteBlobID, object: remoteBlob),
        try PackObject(identifier: remoteTreeID, object: remoteTree),
        try PackObject(identifier: remoteCommitID, object: remoteCommit),
    ])
    let advertisement =
        try PacketLineEncoder.encode(.data(Array("version 2\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("ls-refs=unborn\n".utf8)))
        + PacketLineEncoder.encode(
            .data(Array("fetch=wait-for-done\n".utf8))
        )
        + PacketLineEncoder.encode(
            .data(Array("object-format=sha1\n".utf8))
        )
        + PacketLineEncoder.encode(.flush)
    let references = try PacketLineEncoder.encode(
        .data(Array(
            "\(remoteHex) HEAD symref-target:refs/heads/main\n".utf8
        ))
    ) + PacketLineEncoder.encode(
        .data(Array("\(remoteHex) refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
    let fetch =
        try PacketLineEncoder.encode(.data(Array("packfile\n".utf8)))
        + PacketLineEncoder.encode(.data([1] + archive.pack))
        + PacketLineEncoder.encode(.flush)
    let transport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-upload-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: references,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: fetch,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    let result = try await repository.pull(
        PullRequest(
            fetch: try FetchRequest(remote: remote),
            strategy: .fastForwardOnly,
            author: signature,
            committer: signature
        ),
        services: RepositoryServices(httpTransport: transport)
    ).value()
    guard case .fastForward(let previous, let current) = result.integration else {
        Issue.record("expected pull to fast-forward")
        return
    }
    #expect(previous == base)
    #expect(current.description == remoteHex)
    let upstream = try RefName("refs/remotes/origin/main")
    #expect(result.upstreamReference == upstream)
    #expect(try Data(contentsOf: file) == Data("remote\n".utf8))
    #expect(try await repository.status().value().isClean)
    #expect(await transport.requests.count == 3)
}

@Test func fetchUsesInjectedProtocolV2TransportAndPublishesValidatedPack() async throws {
    let blob = GitObject(type: .blob, payload: Array("network\n".utf8))
    let blobID = SHA1.hash(blob.canonicalBytes)
    let tree = GitObjectEncoder.tree(entries: [
        try GitTreeEntry(mode: .regular, name: Array("file.txt".utf8), objectID: blobID),
    ])
    let treeID = SHA1.hash(tree.canonicalBytes)
    let signature = GitSignature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = GitObjectEncoder.commit(
        treeHex: treeID.map { String(format: "%02x", $0) }.joined(),
        parentHexes: [],
        author: signature,
        committer: signature,
        message: Array("network\n".utf8)
    )
    let commitID = SHA1.hash(commit.canonicalBytes)
    let archive = try PackWriter.write([
        try PackObject(identifier: blobID, object: blob),
        try PackObject(identifier: treeID, object: tree),
        try PackObject(identifier: commitID, object: commit),
    ])
    let commitHex = commitID.map { String(format: "%02x", $0) }.joined()
    let advertisement = try PacketLineEncoder.encode(.data(Array("version 2\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("ls-refs=unborn\n".utf8)))
        + PacketLineEncoder.encode(
            .data(Array("fetch=wait-for-done filter shallow\n".utf8))
        )
        + PacketLineEncoder.encode(.data(Array("object-format=sha1\n".utf8)))
        + PacketLineEncoder.encode(.flush)
    let refs = try PacketLineEncoder.encode(
        .data(Array("\(commitHex) HEAD symref-target:refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(
        .data(Array("\(commitHex) refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
    let fetch =
        try PacketLineEncoder.encode(.data(Array("shallow-info\n".utf8)))
        + PacketLineEncoder.encode(
            .data(Array("shallow \(commitHex)\n".utf8))
        )
        + PacketLineEncoder.encode(.delimiter)
        + PacketLineEncoder.encode(.data(Array("packfile\n".utf8)))
        + PacketLineEncoder.encode(.data([1] + archive.pack))
        + PacketLineEncoder.encode(.flush)
    let remote = try RemoteURL(URL(string: "https://example.test/repository.git")!)
    let transport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: ["content-type": "application/x-git-upload-pack-advertisement"],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: ["content-type": "application/x-git-upload-pack-result"],
            body: refs,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: ["content-type": "application/x-git-upload-pack-result"],
            body: fetch,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let result = try await repository.fetch(
        try FetchRequest(
            remote: remote,
            filter: .blobNone,
            shallow: .depth(2)
        ),
        services: RepositoryServices(
            credentials: GitHubTokenCredentials(token: "secret"),
            httpTransport: transport
        )
    ).value()
    #expect(result.receivedObjects == 3)
    #expect(result.updatedReferences.first?.current.description == commitHex)
    #expect(result.shallowBoundaries.map(\.description) == [commitHex])
    #expect(await repository.capabilities().isShallow)
    let fetchHead = String(
        decoding: try root.directory.read(
            [".git", "FETCH_HEAD"],
            limit: 1024 * 1024
        ),
        as: UTF8.self
    )
    #expect(fetchHead.contains(commitHex))
    #expect(fetchHead.contains("branch 'main' of https://example.test/repository.git"))
    #expect(try await repository.readObject(
        ObjectID(algorithm: .sha1, bytes: commitID)
    ).value().type == .commit)
    let requests = await transport.requests
    #expect(requests.count == 3)
    let authorization = Data("x-access-token:secret".utf8).base64EncodedString()
    #expect(requests.allSatisfy {
        $0.headers["Authorization"] == "Basic \(authorization)"
    })
    #expect(requests[0].headers["Git-Protocol"] == "version=2")
    #expect(String(decoding: requests[1].body, as: UTF8.self).contains("command=ls-refs"))
    #expect(String(decoding: requests[2].body, as: UTF8.self).contains("command=fetch"))
    #expect(
        String(decoding: requests[2].body, as: UTF8.self)
            .contains("filter blob:none")
    )
    #expect(
        String(decoding: requests[2].body, as: UTF8.self)
            .contains("deepen 2")
    )
    let configuration = String(
        decoding: try root.directory.read(
            [".git", "config"],
            limit: 1024 * 1024
        ),
        as: UTF8.self
    )
    #expect(configuration.contains("partialclone = \"origin\""))
    #expect(configuration.contains("promisor = \"true\""))
    #expect(configuration.contains("partialclonefilter = \"blob:none\""))
    let packFiles = try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent(".git/objects/pack").path
    )
    #expect(packFiles.contains { $0.hasSuffix(".promisor") })
    #expect(
        String(
            decoding: try root.directory.read(
                [".git", "shallow"],
                limit: 1024
            ),
            as: UTF8.self
        ) == "\(commitHex)\n"
    )

    let commitOnly = try PackWriter.write([
        try PackObject(identifier: commitID, object: commit),
    ])
    let unshallowResponse =
        try PacketLineEncoder.encode(.data(Array("shallow-info\n".utf8)))
        + PacketLineEncoder.encode(
            .data(Array("unshallow \(commitHex)\n".utf8))
        )
        + PacketLineEncoder.encode(.delimiter)
        + PacketLineEncoder.encode(.data(Array("packfile\n".utf8)))
        + PacketLineEncoder.encode(.data([1] + commitOnly.pack))
        + PacketLineEncoder.encode(.flush)
    let unshallowTransport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-upload-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: refs,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: unshallowResponse,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    let stale = try RefName("refs/remotes/origin/stale")
    _ = try await repository.updateReference(
        stale,
        to: try ObjectID(bytes: commitID)
    ).value()
    let unshallowed = try await repository.fetch(
        try FetchRequest(remote: remote, prune: true),
        services: RepositoryServices(httpTransport: unshallowTransport)
    ).value()
    #expect(unshallowed.shallowBoundaries.isEmpty)
    #expect(unshallowed.prunedReferences == [stale])
    #expect(!(try root.directory.exists([".git", "shallow"])))
    #expect(!(await repository.capabilities().isShallow))
    let unshallowRequests = await unshallowTransport.requests
    #expect(
        String(decoding: unshallowRequests[2].body, as: UTF8.self)
            .contains("shallow \(commitHex)")
    )
}

@Test func readObjectMaterializesMissingPromisorObject() async throws {
    let blob = GitObject(
        type: .blob,
        payload: Array("promised object\n".utf8)
    )
    let identifier = SHA1.hash(blob.canonicalBytes)
    let identifierHex = identifier.map {
        String(format: "%02x", $0)
    }.joined()
    let archive = try PackWriter.write([
        try PackObject(identifier: identifier, object: blob),
    ])
    let advertisement =
        try PacketLineEncoder.encode(.data(Array("version 2\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("fetch=wait-for-done\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("object-format=sha1\n".utf8)))
        + PacketLineEncoder.encode(.flush)
    let fetch =
        try PacketLineEncoder.encode(.data(Array("packfile\n".utf8)))
        + PacketLineEncoder.encode(.data([1] + archive.pack))
        + PacketLineEncoder.encode(.flush)
    let remote = try RemoteURL(
        URL(string: "https://example.test/promisor.git")!
    )
    let transport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-upload-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: fetch,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    _ = try await Treeish.initialize(in: root)
    var configuration = try root.directory.read(
        [".git", "config"],
        limit: 1024 * 1024
    )
    configuration += Array(
        """

        [extensions]
            partialClone = origin
        [remote "origin"]
            url = https://example.test/promisor.git
            promisor = true
            partialCloneFilter = blob:none

        """.utf8
    )
    try root.directory.writeAtomically(
        configuration,
        to: [".git", "config"]
    )
    let repository = try await Treeish.open(
        try await Treeish.discover(in: root),
        roots: [root]
    )

    let object = try await repository.readObject(
        try ObjectID(bytes: identifier),
        services: RepositoryServices(httpTransport: transport)
    ).value()
    #expect(object.type == .blob)
    #expect(object.payload == blob.payload)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(
        String(decoding: requests[1].body, as: UTF8.self)
            .contains("want \(identifierHex)")
    )
    #expect(
        try await repository.readObject(try ObjectID(bytes: identifier))
            .value().payload == blob.payload
    )
}

@Test func checkoutMaterializesFilteredCloneObjects() async throws {
    let blob = GitObject(
        type: .blob,
        payload: Array("checkout promise\n".utf8)
    )
    let blobID = SHA1.hash(blob.canonicalBytes)
    let archive = try PackWriter.write([
        try PackObject(identifier: blobID, object: blob),
    ])
    let advertisement =
        try PacketLineEncoder.encode(.data(Array("version 2\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("fetch=filter\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("object-format=sha1\n".utf8)))
        + PacketLineEncoder.encode(.flush)
    let response =
        try PacketLineEncoder.encode(.data(Array("packfile\n".utf8)))
        + PacketLineEncoder.encode(.data([1] + archive.pack))
        + PacketLineEncoder.encode(.flush)
    let remote = try RemoteURL(
        URL(string: "https://example.test/filtered.git")!
    )
    let transport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-upload-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-upload-pack-result",
            ],
            body: response,
            finalURL: remote.url.appendingPathComponent("git-upload-pack")
        ),
    ])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let tree = GitObjectEncoder.tree(entries: [
        try GitTreeEntry(
            mode: .regular,
            name: Array("promised.txt".utf8),
            objectID: blobID
        ),
    ])
    let treeID = try await repository.writeObject(
        type: .tree,
        payload: tree.payload
    ).value()
    let signature = GitSignature(
        name: "Treeish",
        email: "treeish@example.com",
        secondsSinceEpoch: 1_700_000_000,
        timeZoneOffsetMinutes: 0
    )
    let commit = GitObjectEncoder.commit(
        treeHex: treeID.description,
        parentHexes: [],
        author: signature,
        committer: signature,
        message: Array("filtered checkout\n".utf8)
    )
    let commitID = try await repository.writeObject(
        type: .commit,
        payload: commit.payload
    ).value()
    var configuration = try root.directory.read(
        [".git", "config"],
        limit: 1024 * 1024
    )
    configuration += Array(
        """

        [extensions]
            partialClone = origin
        [remote "origin"]
            url = https://example.test/filtered.git
            promisor = true
            partialCloneFilter = blob:none

        """.utf8
    )
    try root.directory.writeAtomically(
        configuration,
        to: [".git", "config"]
    )
    _ = try await repository.createBranch(
        named: "main",
        at: commitID
    ).value()

    let result = try await repository.checkout(
        CheckoutRequest(
            commit: commitID,
            reference: try RefName("refs/heads/main")
        ),
        services: RepositoryServices(httpTransport: transport)
    ).value()
    #expect(result.pathsWritten == 1)
    #expect(
        try root.directory.read(
            ["promised.txt"],
            limit: 1024
        ) == blob.payload
    )
}

@Test func fetchUsesStatefulSSHUploadPackSession() async throws {
    let blob = GitObject(type: .blob, payload: Array("ssh\n".utf8))
    let blobID = SHA1.hash(blob.canonicalBytes)
    let archive = try PackWriter.write([
        try PackObject(identifier: blobID, object: blob),
    ])
    let identifier = blobID.map { String(format: "%02x", $0) }.joined()
    let advertisement = try PacketLineEncoder.encode(
        .data(Array(
            "\(identifier) HEAD\0side-band-64k ofs-delta symref=HEAD:refs/heads/main\n".utf8
        ))
    ) + PacketLineEncoder.encode(
        .data(Array("\(identifier) refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
    let response = try PacketLineEncoder.encode(
        .data(Array("NAK\n".utf8))
    ) + PacketLineEncoder.encode(
        .data([1] + archive.pack)
    ) + PacketLineEncoder.encode(.flush)
    let session = ScriptedSSHGitSession(
        advertised: advertisement,
        response: response
    )
    let transport = ScriptedSSHGitTransport(session: session)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try await TreeishRoot.localDirectory(at: directory)
    let repository = try await Treeish.initialize(in: root)
    let result = try await repository.fetch(
        try FetchRequest(
            remote: RemoteURL("git@github.com:FauxFoxIO/Treeish.git")
        ),
        services: RepositoryServices(sshTransport: transport)
    ).value()

    #expect(result.receivedObjects == 1)
    #expect(result.remoteHead?.description == "refs/remotes/origin/main")
    #expect(try await repository.readObject(
        ObjectID(algorithm: .sha1, bytes: blobID)
    ).value().payload == blob.payload)
    #expect(await transport.requests.first?.service == .uploadPack)
    #expect(await transport.requests.first?.endpoint.host == "github.com")
    #expect(await session.requests.count == 1)
}

@Test func pushCreatesRemoteReferenceWithCanonicalPackAndReportStatus() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("push\n".utf8).write(
        to: directory.appendingPathComponent("file.txt")
    )
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
    let commit = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("push\n".utf8)
        )
    ).value()
    let zero = String(repeating: "0", count: 40)
    let advertisement = try PacketLineEncoder.encode(
        .data(Array("# service=git-receive-pack\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
        + PacketLineEncoder.encode(
            .data(
                Array(
                    "\(zero) capabilities^{}\0report-status atomic push-options ofs-delta\n".utf8
                )
            )
        )
        + PacketLineEncoder.encode(.flush)
    let status = try PacketLineEncoder.encode(
        .data(Array("unpack ok\n".utf8))
    ) + PacketLineEncoder.encode(
        .data(Array("ok refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
    let remote = try RemoteURL(
        URL(string: "https://example.test/push.git")!
    )
    let transport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-receive-pack-advertisement",
            ],
            body: advertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-receive-pack-result",
            ],
            body: status,
            finalURL: remote.url.appendingPathComponent("git-receive-pack")
        ),
    ])
    let result = try await repository.push(
        try PushRequest(
            remote: remote,
            refspecs: [
                PushRefspec(
                    source: try RefName("refs/heads/main"),
                    destination: try RefName("refs/heads/main")
                ),
            ],
            requiresAtomic: true,
            options: ["ci.skip"]
        ),
        services: RepositoryServices(httpTransport: transport)
    ).value()
    #expect(result.references.first?.current == commit.objectID)
    #expect(result.references.first?.disposition == .accepted)
    let requests = await transport.requests
    #expect(requests.count == 2)
    let body = requests[1].body
    #expect(String(decoding: body.prefix(200), as: UTF8.self).contains(
        "\(zero) \(commit.objectID.description) refs/heads/main"
    ))
    #expect(String(decoding: body, as: UTF8.self).contains("push-options"))
    #expect(String(decoding: body, as: UTF8.self).contains("ci.skip"))
    #expect(body.containsSubsequence(Array("PACK".utf8)))

    let deletionAdvertisement = try PacketLineEncoder.encode(
        .data(
            Array(
                "\(commit.objectID.description) refs/heads/main\0report-status delete-refs\n".utf8
            )
        )
    ) + PacketLineEncoder.encode(.flush)
    let deletionStatus =
        try PacketLineEncoder.encode(.data(Array("unpack ok\n".utf8)))
        + PacketLineEncoder.encode(
            .data(Array("ok refs/heads/main\n".utf8))
        )
        + PacketLineEncoder.encode(.flush)
    let deletionTransport = ScriptedSmartHTTPTransport(responses: [
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type":
                    "application/x-git-receive-pack-advertisement",
            ],
            body: deletionAdvertisement,
            finalURL: remote.url.appendingPathComponent("info/refs")
        ),
        SmartHTTPTransportResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/x-git-receive-pack-result",
            ],
            body: deletionStatus,
            finalURL: remote.url.appendingPathComponent("git-receive-pack")
        ),
    ])
    let deletion = try await repository.push(
        try PushRequest(
            remote: remote,
            refspecs: [
                PushRefspec(
                    source: nil,
                    destination: try RefName("refs/heads/main")
                ),
            ]
        ),
        services: RepositoryServices(httpTransport: deletionTransport)
    ).value()
    #expect(deletion.references.first?.current == nil)
    #expect(deletion.references.first?.disposition == .accepted)
    let deletionRequests = await deletionTransport.requests
    #expect(
        !deletionRequests[1].body.containsSubsequence(Array("PACK".utf8))
    )
}

@Test func pushUsesStatefulSSHReceivePackSession() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("ssh push\n".utf8).write(
        to: directory.appendingPathComponent("file.txt")
    )
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
    let commit = try await repository.commit(
        CommitRequest(
            tree: tree,
            author: signature,
            committer: signature,
            message: Array("ssh push\n".utf8)
        )
    ).value()

    let zero = String(repeating: "0", count: 40)
    let advertisement = try PacketLineEncoder.encode(
        .data(Array(
            "\(zero) capabilities^{}\0report-status ofs-delta\n".utf8
        ))
    ) + PacketLineEncoder.encode(.flush)
    let response = try PacketLineEncoder.encode(
        .data(Array("unpack ok\n".utf8))
    ) + PacketLineEncoder.encode(
        .data(Array("ok refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
    let session = ScriptedSSHGitSession(
        advertised: advertisement,
        response: response
    )
    let transport = ScriptedSSHGitTransport(session: session)

    let result = try await repository.push(
        PushRequest(
            remote: try RemoteURL(
                "ssh://git@github.com/FauxFoxIO/Treeish.git"
            ),
            source: try RefName("refs/heads/main")
        ),
        services: RepositoryServices(sshTransport: transport)
    ).value()

    #expect(result.references.first?.current == commit.objectID)
    #expect(result.references.first?.disposition == .accepted)
    #expect(await transport.requests.first?.service == .receivePack)
    #expect(await session.requests.count == 1)
    let request = try #require(await session.requests.first)
    #expect(String(decoding: request.prefix(200), as: UTF8.self).contains(
        "\(zero) \(commit.objectID.description) refs/heads/main"
    ))
    #expect(request.containsSubsequence(Array("PACK".utf8)))
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ candidate: [UInt8]) -> Bool {
        firstRange(of: candidate) != nil
    }
}
