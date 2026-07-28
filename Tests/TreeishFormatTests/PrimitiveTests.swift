import Testing
@testable import TreeishCore
@testable import TreeishDiff
@testable import TreeishGraph
@testable import TreeishIndex
@testable import TreeishObjects
@testable import TreeishPacks
@testable import TreeishProtocol

@Test func sha1Vectors() {
    let digest = SHA1.hash(Array("abc".utf8))
    let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
    #expect(hexadecimal == "a9993e364706816aba3e25717850c26c9cd0d89d")
}

@Test func boundedTextDiffProducesEdits() throws {
    let result = try DiffEngine.diff(
        old: Array("a\nb\n".utf8),
        new: Array("a\nc\n".utf8)
    )
    guard case .text(let lines) = result else {
        Issue.record("expected text diff")
        return
    }
    #expect(lines.contains(.deletion(Array("b\n".utf8))))
    #expect(lines.contains(.insertion(Array("c\n".utf8))))
}

@Test func unifiedPatchParsesAppliesCreationDeletionAndNoNewline() throws {
    let patch = try UnifiedPatch(bytes: Array("""
    --- a/file.txt
    +++ b/file.txt
    @@ -1,2 +1,2 @@
     one
    -two
    +three
    \\ No newline at end of file
    """.utf8))
    #expect(patch.files.count == 1)
    #expect(
        try patch.files[0].apply(to: Array("one\ntwo\n".utf8))
            == Array("one\nthree".utf8)
    )

    let creation = try UnifiedPatch(bytes: Array("""
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,1 @@
    +new
    """.utf8))
    #expect(try creation.files[0].apply(to: []) == Array("new\n".utf8))

    let deletion = try UnifiedPatch(bytes: Array("""
    --- a/old.txt
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -old
    """.utf8))
    #expect(try deletion.files[0].apply(to: Array("old\n".utf8)).isEmpty)
}

@Test func unifiedPatchRejectsTraversalAndAmbiguousContext() throws {
    #expect(throws: DiffError.self) {
        _ = try UnifiedPatch(bytes: Array("""
        --- a/../outside
        +++ b/../outside
        @@ -0,0 +1,1 @@
        +bad
        """.utf8))
    }
    let patch = try UnifiedPatch(bytes: Array("""
    --- a/file
    +++ b/file
    @@ -2,1 +2,1 @@
     repeated
    """.utf8))
    #expect(throws: DiffError.ambiguousContext) {
        _ = try patch.files[0].apply(to: Array("repeated\nrepeated\n".utf8))
    }
}

@Test func packetLinesDecodeIncrementally() throws {
    let encoded = try PacketLineEncoder.encode(.data(Array("version 2\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("fetch=shallow wait-for-done\n".utf8)))
        + PacketLineEncoder.encode(.flush)
    var decoder = PacketLineDecoder()
    let first = try decoder.append(encoded.prefix(5))
    #expect(first.isEmpty)
    let remaining = try decoder.append(encoded.dropFirst(5))
    try decoder.finish()
    let advertisement = try ProtocolV2Advertisement(packets: remaining)
    #expect(advertisement.capabilities["fetch"] == ["shallow", "wait-for-done"])
}

@Test func nonDeltaPackVerifiesWithGit() throws {
    let object = GitObject(type: .blob, payload: Array("packed\n".utf8))
    let identifier = SHA1.hash(object.canonicalBytes)
    let archive = try PackWriter.write([
        try PackObject(identifier: identifier, object: object),
    ])
    #expect(Array(archive.pack.prefix(4)) == Array("PACK".utf8))
    #expect(Array(archive.index.prefix(4)) == [0xff, 0x74, 0x4f, 0x63])
    let decoded = try PackReader.read(archive.pack)
    #expect(decoded.object(identifier: identifier) == object)
    let index = try PackIndexV2.read(archive.index)
    #expect(index.contains(identifier))
    #expect(index.entries.first?.offset == 12)
}

@Test func thinPackResolvesExternalBaseAndEnforcesAggregateBudget() throws {
    let base = GitObject(type: .blob, payload: Array("base\n".utf8))
    let baseID = SHA1.hash(base.canonicalBytes)
    let target = Array("changed\n".utf8)
    let delta = [UInt8(base.payload.count), UInt8(target.count), UInt8(target.count)]
        + target
    var pack = Array("PACK".utf8)
    for value: UInt32 in [2, 1] {
        pack += [
            UInt8(value >> 24),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }
    pack.append(0x70 | UInt8(delta.count))
    pack += baseID
    pack += try Zlib.compress(delta)
    pack += SHA1.hash(pack)

    let decoded = try PackReader.read(pack) { identifier in
        identifier == baseID ? base : nil
    }
    #expect(decoded.objects.first?.object.payload == target)
    #expect(throws: PackReadError.resourceLimitExceeded) {
        _ = try PackReader.read(
            pack,
            limits: PackLimits(maximumResolvedBytes: target.count - 1),
            externalBase: { _ in base }
        )
    }
}

@Test func zlibRoundTrip() throws {
    let bytes = Array(repeating: Array("treeish".utf8), count: 1_000).flatMap { $0 }
    #expect(try Zlib.decompress(Zlib.compress(bytes)) == bytes)
    #expect(try Zlib.decompress(Zlib.compress([])).isEmpty)
}

@Test func zlibReadsCanonicalStreamsAndStopsBeforeFollowingBytes() throws {
    let canonical: [UInt8] = [
        0x78, 0x9c,
        0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00,
        0x06, 0x2c, 0x02, 0x15,
    ]
    let decoded = try Zlib.decompressPrefix(
        canonical + [0xaa, 0xbb, 0xcc]
    )
    #expect(decoded.bytes == Array("hello".utf8))
    #expect(decoded.consumedInputBytes == canonical.count)

    var corrupt = canonical
    corrupt[corrupt.count - 1] ^= 0xff
    #expect(throws: ZlibError.checksumMismatch) {
        _ = try Zlib.decompress(corrupt)
    }
    #expect(throws: ZlibError.resourceLimitExceeded) {
        _ = try Zlib.decompress(canonical, maximumOutputBytes: 4)
    }
}

@Test func canonicalBlobBytes() {
    let object = GitObject(type: .blob, payload: Array("hello\n".utf8))
    #expect(object.canonicalBytes == Array("blob 6\0hello\n".utf8))
}

@Test func indexV2RoundTrip() throws {
    let entry = try GitIndexEntry(
        path: Array("Sources/File.swift".utf8),
        objectID: Array(repeating: 0x12, count: 20),
        mode: 0o100644,
        size: 42,
        modificationSeconds: 100,
        modificationNanoseconds: 200
    )
    let index = GitIndex(entries: [entry])
    #expect(try GitIndex.decode(index.encode()) == index)
}

@Test func indexV3AndV4RoundTripExtendedFlagsAndCompressedPaths() throws {
    let entries = try [
        GitIndexEntry(
            path: Array("Sources/Treeish/File.swift".utf8),
            objectID: [UInt8](repeating: 0x11, count: 20),
            mode: 0o100644,
            size: 12,
            modificationSeconds: 1,
            modificationNanoseconds: 2,
            assumeValid: true,
            skipWorktree: true
        ),
        GitIndexEntry(
            path: Array("Sources/Treeish/Folder.swift".utf8),
            objectID: [UInt8](repeating: 0x22, count: 20),
            mode: 0o100755,
            size: 34,
            modificationSeconds: 3,
            modificationNanoseconds: 4,
            intentToAdd: true
        ),
    ]
    for version: UInt32 in [3, 4] {
        let index = GitIndex(version: version, entries: entries)
        let decoded = try GitIndex.decode(index.encode())
        #expect(decoded == index)
    }
}

@Test func receivePackRequestCarriesCompareAndSwapAndPack() throws {
    let old = [UInt8](repeating: 0x11, count: 20)
    let new = [UInt8](repeating: 0x22, count: 20)
    let command = try ReceivePackCommand(
        old: old,
        new: new,
        name: Array("refs/heads/main".utf8)
    )
    let pack = Array("PACKpayload".utf8)
    let request = try ReceivePackV0.request(
        commands: [command],
        pack: pack,
        advertisedCapabilities: ["report-status", "side-band-64k"]
    )
    #expect(request.suffix(pack.count).elementsEqual(pack))
    #expect(String(decoding: request, as: UTF8.self).contains("refs/heads/main"))
    #expect(String(decoding: request, as: UTF8.self).contains("report-status"))
}

@Test func receivePackParsesReportStatus() throws {
    let status = try PacketLineEncoder.encode(.data(Array("unpack ok\n".utf8)))
        + PacketLineEncoder.encode(.data(Array("ok refs/heads/main\n".utf8)))
        + PacketLineEncoder.encode(.flush)
    let response = try PacketLineEncoder.encode(.data([1] + status))
        + PacketLineEncoder.encode(.flush)
    let result = try ReceivePackV0.parseResponse(response, sideband: true)
    #expect(result.unpacked)
    #expect(result.statuses == [.accepted(Array("refs/heads/main".utf8))])
}

@Test func uploadPackV2NegotiatesRefsAndPackfileSections() throws {
    let capabilities = try UploadPackV2.parseCapabilities([
        .data(Array("version 2\n".utf8)),
        .data(Array("ls-refs=unborn\n".utf8)),
        .data(Array("fetch=shallow wait-for-done\n".utf8)),
        .data(Array("object-format=sha1\n".utf8)),
        .flush,
    ])
    #expect(capabilities.supports("ls-refs"))
    #expect(capabilities.supports("fetch"))
    let lsRequest = try UploadPackV2.lsRefsRequest(
        prefixes: [Array("refs/heads/".utf8)],
        capabilities: capabilities
    )
    #expect(String(decoding: lsRequest, as: UTF8.self).contains("command=ls-refs"))
    let object = [UInt8](repeating: 0x12, count: 20)
    let hex = object.map { String(format: "%02x", $0) }.joined()
    let refs = try UploadPackV2.parseLsRefs([
        .data(Array("\(hex) HEAD symref-target:refs/heads/main\n".utf8)),
        .data(Array("\(hex) refs/heads/main\n".utf8)),
        .flush,
    ])
    #expect(refs.symbolicHead == "refs/heads/main")
    #expect(refs.references.count == 2)
    let fetch = try UploadPackV2.fetchRequest(wants: [object], capabilities: capabilities)
    #expect(String(decoding: fetch, as: UTF8.self).contains("command=fetch"))
    let pack = Array("PACKpayload".utf8)
    #expect(try UploadPackV2.parseFetchResponse([
        .data(Array("acknowledgments\n".utf8)),
        .delimiter,
        .data(Array("packfile\n".utf8)),
        .data([1] + pack),
        .flush,
    ]) == pack)
}

@Test func receivePackEncodesMultipleUpdatesAndDeletionAtomically() throws {
    let zero = [UInt8](repeating: 0, count: 20)
    let first = try ReceivePackCommand(
        old: [UInt8](repeating: 0x11, count: 20),
        new: [UInt8](repeating: 0x22, count: 20),
        name: Array("refs/heads/main".utf8)
    )
    let deletion = try ReceivePackCommand(
        old: [UInt8](repeating: 0x33, count: 20),
        new: zero,
        name: Array("refs/heads/old".utf8)
    )
    let request = try ReceivePackV0.request(
        commands: [first, deletion],
        pack: Array("PACK".utf8),
        advertisedCapabilities: ["report-status", "atomic"]
    )
    let text = String(decoding: request, as: UTF8.self)
    #expect(text.contains("refs/heads/main"))
    #expect(text.contains("refs/heads/old"))
    #expect(text.contains("atomic"))
    #expect(text.contains(String(repeating: "0", count: 40)))
}
