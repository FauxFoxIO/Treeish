import Foundation
import TreeishCore
import TreeishFileSystem
import TreeishGraph
import TreeishObjects
import TreeishPacks

final class RepositoryObjectStore: @unchecked Sendable {
    private let loose: LooseObjectStore
    private let directory: RootDirectory
    private let objectDirectories: [RootDirectory]
    private let limits: TreeishResourceLimits
    private var shallowIdentifiers: Set<[UInt8]>
    private var replacementObjects: [[UInt8]: [UInt8]]
    private let useMultiPackIndex: Bool
    let objectFormat: GitHashAlgorithm
    private let lock = NSLock()
    private var cachedPacks: [String: PackFile] = [:]
    private var cachedIndexes: [String: PackIndexV2] = [:]
    private var cachedMultiPackIndexes: [String: MultiPackIndex] = [:]

    init(
        directory: RootDirectory,
        grantedRoot: RootDirectory,
        objectFormat: GitHashAlgorithm,
        limits: TreeishResourceLimits,
        replacementObjects: [[UInt8]: [UInt8]]
    ) throws {
        loose = LooseObjectStore(
            gitDirectory: directory,
            algorithm: objectFormat,
            limits: limits
        )
        self.directory = directory
        self.objectFormat = objectFormat
        self.limits = limits
        let primary = try directory.childDirectory(["objects"])
        objectDirectories = try Self.loadObjectDirectories(
            primary: primary,
            grantedRoot: grantedRoot
        )
        shallowIdentifiers = try Self.loadShallowIdentifiers(
            directory: directory,
            objectFormat: objectFormat
        )
        self.replacementObjects = replacementObjects
        let configuration = try GitConfiguration.load(from: directory)
        let multiPackIndexValue = configuration.value(
            section: "core",
            key: "multipackindex"
        )?.lowercased()
        useMultiPackIndex = ![
            "false", "no", "off", "0",
        ].contains(multiPackIndexValue)
    }

    func write(_ object: GitObject) throws -> [UInt8] {
        try loose.write(object)
    }

    func read(identifier: [UInt8]) throws -> GitObject {
        var resolved = identifier
        var visited: Set<[UInt8]> = []
        while let replacement = lock.withLock({
            replacementObjects[resolved]
        }) {
            guard visited.count < 16,
                  visited.insert(resolved).inserted else {
                throw TreeishError.recoveryRequired(
                    "replacement object cycle"
                )
            }
            resolved = replacement
        }
        return try readUnreplaced(identifier: resolved)
    }

    func readRaw(identifier: [UInt8]) throws -> GitObject {
        try readUnreplaced(identifier: identifier)
    }

    func allIdentifiers(limit: Int = 10_000_000) throws -> Set<[UInt8]> {
        guard limit >= 0 else { throw ZlibError.resourceLimitExceeded }
        var identifiers: Set<[UInt8]> = []
        for objectDirectory in objectDirectories {
            let root = try objectDirectory.url(for: [])
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for fanout in entries {
                let prefix = fanout.lastPathComponent.lowercased()
                guard prefix.count == 2,
                      prefix.allSatisfy(\.isHexDigit),
                      (try? fanout.resourceValues(
                        forKeys: [.isDirectoryKey]
                      ).isDirectory) == true else {
                    continue
                }
                let objects = (try? FileManager.default.contentsOfDirectory(
                    at: fanout,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for object in objects {
                    let suffix = object.lastPathComponent.lowercased()
                    let hexadecimal = prefix + suffix
                    guard hexadecimal.count == objectFormat.byteCount * 2,
                          hexadecimal.allSatisfy(\.isHexDigit),
                          let identifier = decodeHex(hexadecimal) else {
                        continue
                    }
                    identifiers.insert(identifier)
                    guard identifiers.count <= limit else {
                        throw ZlibError.resourceLimitExceeded
                    }
                }
            }
            let packDirectory = try objectDirectory.url(for: ["pack"])
            let packs = (try? FileManager.default.contentsOfDirectory(
                at: packDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in packs where url.pathExtension == "pack" {
                for entry in try loadPack(
                    url: url,
                    objectDirectory: objectDirectory
                ).objects {
                    identifiers.insert(entry.identifier)
                    guard identifiers.count <= limit else {
                        throw ZlibError.resourceLimitExceeded
                    }
                }
            }
        }
        return identifiers
    }

    func setReplacement(
        for original: [UInt8],
        to replacement: [UInt8]?
    ) {
        lock.withLock {
            replacementObjects[original] = replacement
        }
    }

    private func readUnreplaced(identifier: [UInt8]) throws -> GitObject {
        do {
            return try loose.read(identifier: identifier)
        } catch GitObjectError.objectNotFound {
            // Continue through alternates and canonical pack storage.
        }
        for objectDirectory in objectDirectories.dropFirst() {
            if let object = try readLoose(
                identifier: identifier,
                from: objectDirectory
            ) {
                return object
            }
        }
        for objectDirectory in objectDirectories {
            for pack in try packs(
                containing: identifier,
                in: objectDirectory
            ) {
                if let object = pack.object(identifier: identifier) {
                    return object
                }
            }
        }
        throw GitObjectError.objectNotFound
    }

    func commitGraphObject(identifier: [UInt8]) throws -> GitObject {
        let object = try read(identifier: identifier)
        guard lock.withLock({
            shallowIdentifiers.contains(identifier)
        }),
              object.type == .commit else {
            return object
        }
        let separator = Array("\n\n".utf8)
        guard let range = object.payload.firstRange(of: separator) else {
            throw CommitGraphError.malformedCommit
        }
        let headers = object.payload[..<range.lowerBound]
            .split(separator: 0x0a, omittingEmptySubsequences: false)
            .filter { !$0.starts(with: Array("parent ".utf8)) }
        var payload = Array(headers.joined(separator: [0x0a]))
        payload.append(contentsOf: separator)
        payload.append(contentsOf: object.payload[range.upperBound...])
        return GitObject(type: .commit, payload: payload)
    }

    func setShallowIdentifiers(_ identifiers: Set<[UInt8]>) {
        lock.withLock {
            shallowIdentifiers = identifiers
        }
    }

    func isShallow(_ identifier: [UInt8]) -> Bool {
        lock.withLock { shallowIdentifiers.contains(identifier) }
    }

    func resolvePrefix(_ hexadecimal: String) throws -> [UInt8]? {
        guard hexadecimal.count >= 4,
              hexadecimal.count < objectFormat.byteCount * 2,
              hexadecimal.allSatisfy(\.isHexDigit) else {
            return nil
        }
        let prefix = hexadecimal.lowercased()
        var matches: Set<[UInt8]> = []
        for objectDirectory in objectDirectories {
            let objectsURL = try objectDirectory.url(for: [])
            let fanout = (try? FileManager.default.contentsOfDirectory(
                at: objectsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for folder in fanout where folder.lastPathComponent.count == 2 {
                let namePrefix = folder.lastPathComponent.lowercased()
                guard prefix.hasPrefix(namePrefix) || namePrefix.hasPrefix(prefix) else {
                    continue
                }
                let names = (try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for file in names {
                    let value = namePrefix + file.lastPathComponent.lowercased()
                    guard value.count == objectFormat.byteCount * 2,
                          value.hasPrefix(prefix),
                          let identifier = decodeHex(value)
                    else { continue }
                    matches.insert(identifier)
                }
            }
            let packURL = try objectDirectory.url(for: ["pack"])
            for multiPackIndex in try multiPackIndexes(
                in: objectDirectory
            ) {
                for entry in multiPackIndex.entries {
                    let value = entry.identifier.map {
                        String(format: "%02x", $0)
                    }.joined()
                    if value.hasPrefix(prefix) {
                        matches.insert(entry.identifier)
                    }
                }
            }
            let indexes = (try? FileManager.default.contentsOfDirectory(
                at: packURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in indexes where url.pathExtension == "idx" {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size <= limits.maximumPackBytes else {
                    throw PackReadError.resourceLimitExceeded
                }
                let bytes = try Data(contentsOf: url)
                for entry in try PackIndexV2.read(
                    Array(bytes),
                    objectFormat: objectFormat
                ).entries {
                    let value = entry.identifier.map {
                        String(format: "%02x", $0)
                    }.joined()
                    if value.hasPrefix(prefix) {
                        matches.insert(entry.identifier)
                    }
                }
            }
        }
        guard matches.count <= 1 else { throw TreeishError.referenceChanged }
        return matches.first
    }

    private func decodeHex(_ value: String) -> [UInt8]? {
        guard value.count == objectFormat.byteCount * 2 else { return nil }
        var result: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private func packs(
        containing identifier: [UInt8],
        in objectDirectory: RootDirectory
    ) throws -> [PackFile] {
        let packDirectory = try objectDirectory.url(for: ["pack"])
        for index in try multiPackIndexes(in: objectDirectory) {
            if let entry = index.entry(for: identifier) {
                let packName = String(entry.packName.dropLast(4)) + ".pack"
                let url = packDirectory.appendingPathComponent(packName)
                return [
                    try loadPack(
                        url: url,
                        objectDirectory: objectDirectory
                    ),
                ]
            }
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: packDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [PackFile] = []
        for url in urls where url.pathExtension == "pack" {
            let indexName = url.deletingPathExtension().appendingPathExtension("idx").lastPathComponent
            if try objectDirectory.exists(["pack", indexName]) {
                let values = try url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                guard let size = values.fileSize,
                      size <= limits.maximumPackBytes else {
                    throw PackReadError.resourceLimitExceeded
                }
                let key = "\(objectDirectory.identity.canonicalPath):\(url.lastPathComponent):\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                let index: PackIndexV2
                if let cached = lock.withLock({ cachedIndexes[key] }) {
                    index = cached
                } else {
                    let indexBytes = try objectDirectory.read(
                        ["pack", indexName],
                        limit: limits.maximumPackBytes
                    )
                    index = try PackIndexV2.read(
                        indexBytes,
                        objectFormat: objectFormat
                    )
                    lock.withLock { cachedIndexes[key] = index }
                }
                guard index.contains(identifier) else { continue }
            }
            result.append(try loadPack(
                url: url,
                objectDirectory: objectDirectory
            ))
        }
        return result
    }

    private func loadPack(
        url: URL,
        objectDirectory: RootDirectory
    ) throws -> PackFile {
        let values = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        guard let size = values.fileSize,
              size <= limits.maximumPackBytes else {
            throw PackReadError.resourceLimitExceeded
        }
        let prefix = "\(objectDirectory.identity.canonicalPath):\(url.lastPathComponent):"
        let key = "\(prefix)\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached = lock.withLock({ cachedPacks[key] }) {
            return cached
        }
        let bytes = try objectDirectory.read(
            ["pack", url.lastPathComponent],
            limit: limits.maximumPackBytes
        )
        let pack = try PackReader.read(
            bytes,
            objectFormat: objectFormat,
            limits: PackLimits(
                maximumObjectBytes: limits.maximumObjectBytes,
                maximumDeltaDepth: limits.maximumDeltaDepth
            )
        )
        lock.withLock {
            cachedPacks = cachedPacks.filter { !$0.key.hasPrefix(prefix) }
            cachedPacks[key] = pack
        }
        return pack
    }

    private func multiPackIndexes(
        in objectDirectory: RootDirectory
    ) throws -> [MultiPackIndex] {
        guard useMultiPackIndex else { return [] }
        var paths: [[String]] = []
        if try objectDirectory.exists(["pack", "multi-pack-index"]) {
            paths.append(["pack", "multi-pack-index"])
        }
        let chainPath = [
            "pack", "multi-pack-index.d", "multi-pack-index-chain",
        ]
        if try objectDirectory.exists(chainPath) {
            let bytes = try objectDirectory.read(
                chainPath,
                limit: 16 * 1024 * 1024
            )
            let hashes = bytes.split(
                separator: 0x0a,
                omittingEmptySubsequences: true
            )
            guard hashes.count <= 65_536,
                  hashes.allSatisfy({
                      $0.count == objectFormat.byteCount * 2 &&
                      $0.allSatisfy {
                          (0x30...0x39).contains($0)
                              || (0x61...0x66).contains($0)
                      }
                  }) else {
                throw PackReadError.indexMismatch
            }
            paths += hashes.reversed().map {
                [
                    "pack",
                    "multi-pack-index.d",
                    "multi-pack-index-\(String(decoding: $0, as: UTF8.self)).midx",
                ]
            }
        }
        return try paths.map {
            try loadMultiPackIndex(
                path: $0,
                objectDirectory: objectDirectory
            )
        }
    }

    private func loadMultiPackIndex(
        path: [String],
        objectDirectory: RootDirectory
    ) throws -> MultiPackIndex {
        let url = try objectDirectory.url(for: path)
        let values = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        guard let size = values.fileSize,
              size <= limits.maximumPackBytes else {
            throw PackReadError.resourceLimitExceeded
        }
        let prefix = "\(objectDirectory.identity.canonicalPath):\(path.joined(separator: "/")):"
        let key = "\(prefix)\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached = lock.withLock({ cachedMultiPackIndexes[key] }) {
            return cached
        }
        let bytes = try objectDirectory.read(
            path,
            limit: limits.maximumPackBytes
        )
        let index = try MultiPackIndex.read(
            bytes,
            objectFormat: objectFormat
        )
        lock.withLock {
            cachedMultiPackIndexes = cachedMultiPackIndexes.filter {
                !$0.key.hasPrefix(prefix)
            }
            cachedMultiPackIndexes[key] = index
        }
        return index
    }

    private func readLoose(
        identifier: [UInt8],
        from objectDirectory: RootDirectory
    ) throws -> GitObject? {
        guard identifier.count == objectFormat.byteCount else { return nil }
        let hexadecimal = identifier.map {
            String(format: "%02x", $0)
        }.joined()
        let compressed: [UInt8]
        do {
            compressed = try objectDirectory.read(
                [
                    String(hexadecimal.prefix(2)),
                    String(hexadecimal.dropFirst(2)),
                ],
                limit: limits.maximumObjectBytes
            )
        } catch RootDirectoryError.notFound {
            return nil
        }
        let canonical = try Zlib.decompress(
            compressed,
            maximumOutputBytes: limits.maximumObjectBytes
        )
        guard objectFormat.hash(canonical) == identifier else {
            throw GitObjectError.hashMismatch
        }
        return try GitObject.decodeCanonical(
            canonical,
            maximumPayloadBytes: limits.maximumObjectBytes
        )
    }

    private static func loadObjectDirectories(
        primary: RootDirectory,
        grantedRoot: RootDirectory
    ) throws -> [RootDirectory] {
        var result: [RootDirectory] = []
        var visited: Set<RootDirectoryIdentity> = []

        func visit(_ directory: RootDirectory, depth: Int) throws {
            guard depth <= 8, result.count < 128 else {
                throw ZlibError.resourceLimitExceeded
            }
            guard visited.insert(directory.identity).inserted else { return }
            result.append(directory)
            let bytes: [UInt8]
            do {
                bytes = try directory.read(
                    ["info", "alternates"],
                    limit: 1024 * 1024
                )
            } catch RootDirectoryError.notFound {
                return
            }
            for line in bytes.split(
                separator: 0x0a,
                omittingEmptySubsequences: true
            ) {
                guard !line.contains(0),
                      let path = String(bytes: line, encoding: .utf8),
                      !path.isEmpty else {
                    throw TreeishError.pathEncodingUnsupported
                }
                let base = try directory.url(for: [])
                let url = URL(
                    fileURLWithPath: path,
                    relativeTo: base
                ).standardizedFileURL
                let components = try grantedRoot.relativeComponents(for: url)
                try visit(
                    grantedRoot.childDirectory(components),
                    depth: depth + 1
                )
            }
        }
        try visit(primary, depth: 0)
        return result
    }

    private static func loadShallowIdentifiers(
        directory: RootDirectory,
        objectFormat: GitHashAlgorithm
    ) throws -> Set<[UInt8]> {
        let bytes: [UInt8]
        do {
            bytes = try directory.read(
                ["shallow"],
                limit: 64 * 1024 * 1024
            )
        } catch RootDirectoryError.notFound {
            return []
        }
        let lines = bytes.split(
            separator: 0x0a,
            omittingEmptySubsequences: true
        )
        guard lines.count <= 1_000_000 else {
            throw ZlibError.resourceLimitExceeded
        }
        var result: Set<[UInt8]> = []
        for line in lines {
            guard line.count == objectFormat.byteCount * 2,
                  let text = String(bytes: line, encoding: .utf8)
            else { throw TreeishError.invalidObjectID }
            var identifier: [UInt8] = []
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index..<next], radix: 16) else {
                    throw TreeishError.invalidObjectID
                }
                identifier.append(byte)
                index = next
            }
            result.insert(identifier)
        }
        return result
    }
}

private extension Array where Element: Equatable {
    func firstRange(of needle: [Element]) -> Range<Int>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        for index in 0...(count - needle.count)
        where self[index..<(index + needle.count)].elementsEqual(needle) {
            return index..<(index + needle.count)
        }
        return nil
    }
}
