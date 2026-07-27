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
        + PacketLineEncoder.encode(.data(Array("fetch=wait-for-done\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("object-format=sha1\n".utf8)))
        + PacketLineEncoder.encode(.flush)
    let refs = try PacketLineEncoder.encode(
        .data(Array("\(commitHex) HEAD symref-target:refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(
        .data(Array("\(commitHex) refs/heads/main\n".utf8))
    ) + PacketLineEncoder.encode(.flush)
    let fetch = try PacketLineEncoder.encode(.data(Array("packfile\n".utf8)))
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
        try FetchRequest(remote: remote),
        services: RepositoryServices(httpTransport: transport)
    ).value()
    #expect(result.receivedObjects == 3)
    #expect(result.updatedReferences.first?.current.description == commitHex)
    #expect(try await repository.readObject(
        ObjectID(algorithm: .sha1, bytes: commitID)
    ).value().type == .commit)
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests[0].headers["Git-Protocol"] == "version=2")
    #expect(String(decoding: requests[1].body, as: UTF8.self).contains("command=ls-refs"))
    #expect(String(decoding: requests[2].body, as: UTF8.self).contains("command=fetch"))
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
                    "\(zero) capabilities^{}\0report-status atomic ofs-delta\n".utf8
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
            ]
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
    #expect(body.containsSubsequence(Array("PACK".utf8)))
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ candidate: [UInt8]) -> Bool {
        firstRange(of: candidate) != nil
    }
}
