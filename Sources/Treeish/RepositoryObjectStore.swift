import Foundation
import TreeishCore
import TreeishFileSystem
import TreeishObjects
import TreeishPacks

final class RepositoryObjectStore: @unchecked Sendable {
    private let loose: LooseObjectStore
    private let directory: RootDirectory
    private let limits: TreeishResourceLimits
    let objectFormat: GitHashAlgorithm
    private let lock = NSLock()
    private var cachedPacks: [String: PackFile] = [:]
    private var cachedIndexes: [String: PackIndexV2] = [:]

    init(
        directory: RootDirectory,
        objectFormat: GitHashAlgorithm,
        limits: TreeishResourceLimits
    ) {
        loose = LooseObjectStore(
            gitDirectory: directory,
            algorithm: objectFormat,
            limits: limits
        )
        self.directory = directory
        self.objectFormat = objectFormat
        self.limits = limits
    }

    func write(_ object: GitObject) throws -> [UInt8] {
        try loose.write(object)
    }

    func read(identifier: [UInt8]) throws -> GitObject {
        do {
            return try loose.read(identifier: identifier)
        } catch GitObjectError.objectNotFound {
            // Continue into canonical pack storage.
        }
        for pack in try packs(containing: identifier) {
            if let object = pack.object(identifier: identifier) { return object }
        }
        throw GitObjectError.objectNotFound
    }

    func resolvePrefix(_ hexadecimal: String) throws -> [UInt8]? {
        guard hexadecimal.count >= 4,
              hexadecimal.count < objectFormat.byteCount * 2,
              hexadecimal.allSatisfy(\.isHexDigit) else {
            return nil
        }
        let prefix = hexadecimal.lowercased()
        var matches: Set<[UInt8]> = []
        let objectsURL = try directory.url(for: ["objects"])
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
        let packURL = try directory.url(for: ["objects", "pack"])
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

    private func packs(containing identifier: [UInt8]) throws -> [PackFile] {
        let packDirectory = try directory.url(for: ["objects", "pack"])
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: packDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [PackFile] = []
        for url in urls where url.pathExtension == "pack" {
            let values = try url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            guard let size = values.fileSize, size <= limits.maximumPackBytes else {
                throw PackReadError.resourceLimitExceeded
            }
            let key = "\(url.lastPathComponent):\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            let indexName = url.deletingPathExtension().appendingPathExtension("idx").lastPathComponent
            if try directory.exists(["objects", "pack", indexName]) {
                let index: PackIndexV2
                if let cached = lock.withLock({ cachedIndexes[key] }) {
                    index = cached
                } else {
                    let indexBytes = try directory.read(
                        ["objects", "pack", indexName],
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
            if let cached = lock.withLock({ cachedPacks[key] }) {
                result.append(cached)
                continue
            }
            let bytes = try directory.read(
                ["objects", "pack", url.lastPathComponent],
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
                cachedPacks = cachedPacks.filter { $0.key.hasPrefix(url.lastPathComponent + ":") }
                cachedPacks[key] = pack
            }
            result.append(pack)
        }
        return result
    }
}
