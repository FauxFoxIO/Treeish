import Foundation
import TreeishCore
import TreeishObjects

public struct PackLimits: Sendable, Hashable, Codable {
    public var maximumObjects: Int
    public var maximumObjectBytes: Int
    public var maximumResolvedBytes: Int
    public var maximumDeltaDepth: Int

    public init(
        maximumObjects: Int = 10_000_000,
        maximumObjectBytes: Int = 512 * 1024 * 1024,
        maximumResolvedBytes: Int = 2 * 1024 * 1024 * 1024,
        maximumDeltaDepth: Int = 64
    ) {
        self.maximumObjects = maximumObjects
        self.maximumObjectBytes = maximumObjectBytes
        self.maximumResolvedBytes = maximumResolvedBytes
        self.maximumDeltaDepth = maximumDeltaDepth
    }
}

public enum PackReadError: Error, Sendable, Equatable {
    case truncated
    case invalidSignature
    case unsupportedVersion(UInt32)
    case checksumMismatch
    case resourceLimitExceeded
    case invalidEntry
    case missingDeltaBase
    case cyclicDelta
    case deltaSizeMismatch
    case indexMismatch
}

public struct ResolvedPackObject: Sendable, Hashable {
    public let offset: Int
    public let identifier: [UInt8]
    public let object: GitObject
}

public struct PackFile: Sendable, Hashable {
    public let version: UInt32
    public let objectFormat: GitHashAlgorithm
    public let checksum: [UInt8]
    public let objects: [ResolvedPackObject]

    public func object(identifier: [UInt8]) -> GitObject? {
        objects.first { $0.identifier == identifier }?.object
    }
}

public enum PackReader {
    public typealias ExternalBaseResolver =
        @Sendable (_ identifier: [UInt8]) throws -> GitObject?

    private enum Base: Hashable {
        case none(GitObjectType)
        case offset(Int)
        case identifier([UInt8])
    }

    private struct Entry: Hashable {
        let offset: Int
        let base: Base
        let declaredSize: Int
        let data: [UInt8]
    }

    public static func read(
        _ bytes: [UInt8],
        objectFormat: GitHashAlgorithm = .sha1,
        limits: PackLimits = .init(),
        externalBase: ExternalBaseResolver? = nil
    ) throws -> PackFile {
        let hashLength = objectFormat.byteCount
        guard bytes.count >= 12 + hashLength else {
            throw PackReadError.truncated
        }
        let content = Array(bytes.dropLast(hashLength))
        let checksum = Array(bytes.suffix(hashLength))
        guard objectFormat.hash(content) == checksum else {
            throw PackReadError.checksumMismatch
        }
        var reader = CheckedByteReader(content)
        guard Array(try reader.read(count: 4)) == Array("PACK".utf8) else {
            throw PackReadError.invalidSignature
        }
        let version = try reader.readUInt32BE()
        guard version == 2 || version == 3 else {
            throw PackReadError.unsupportedVersion(version)
        }
        let count = Int(try reader.readUInt32BE())
        guard count <= limits.maximumObjects else {
            throw PackReadError.resourceLimitExceeded
        }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let offset = reader.offset
            let first = try reader.readByte()
            let type = (first >> 4) & 0x7
            var size = UInt64(first & 0x0f)
            var shift: UInt64 = 4
            var continuation = first & 0x80 != 0
            while continuation {
                guard shift < 64 else { throw PackReadError.invalidEntry }
                let byte = try reader.readByte()
                size |= UInt64(byte & 0x7f) << shift
                shift += 7
                continuation = byte & 0x80 != 0
            }
            guard size <= UInt64(limits.maximumObjectBytes) else {
                throw PackReadError.resourceLimitExceeded
            }
            let base: Base
            switch type {
            case 1: base = .none(.commit)
            case 2: base = .none(.tree)
            case 3: base = .none(.blob)
            case 4: base = .none(.tag)
            case 6:
                var byte = try reader.readByte()
                var distance = UInt64(byte & 0x7f)
                while byte & 0x80 != 0 {
                    byte = try reader.readByte()
                    guard distance < (UInt64.max >> 7) else {
                        throw PackReadError.invalidEntry
                    }
                    distance = ((distance + 1) << 7) | UInt64(byte & 0x7f)
                }
                guard distance <= UInt64(offset) else {
                    throw PackReadError.invalidEntry
                }
                base = .offset(offset - Int(distance))
            case 7:
                base = .identifier(Array(try reader.read(count: hashLength)))
            default:
                throw PackReadError.invalidEntry
            }
            let remaining = Array(content[reader.offset...])
            let decompressed = try Zlib.decompressPrefix(
                remaining,
                maximumOutputBytes: limits.maximumObjectBytes
            )
            guard decompressed.bytes.count == Int(size) else {
                throw PackReadError.deltaSizeMismatch
            }
            reader = CheckedByteReader(content)
            _ = try reader.read(count: offset + (readerOffsetAfterHeader(
                content: content,
                entryOffset: offset,
                compressedStart: content.count - remaining.count
            )) + decompressed.consumedInputBytes)
            entries.append(
                Entry(
                    offset: offset,
                    base: base,
                    declaredSize: Int(size),
                    data: decompressed.bytes
                )
            )
        }
        guard reader.remainingCount == 0 else { throw PackReadError.invalidEntry }

        let byOffset = Dictionary(uniqueKeysWithValues: entries.map { ($0.offset, $0) })
        var cache: [Int: GitObject] = [:]
        var idCache: [[UInt8]: GitObject] = [:]
        var unresolved = entries
        var progress = true
        while !unresolved.isEmpty, progress {
            progress = false
            for entry in unresolved {
                if let object = try resolve(
                    entry,
                    byOffset: byOffset,
                    byIdentifier: idCache,
                    externalBase: externalBase,
                    objectFormat: objectFormat,
                    cache: &cache,
                    visiting: [],
                    depth: 0,
                    limits: limits
                ) {
                    let identifier = objectFormat.hash(object.canonicalBytes)
                    idCache[identifier] = object
                    progress = true
                }
            }
            unresolved.removeAll { cache[$0.offset] != nil }
        }
        guard unresolved.isEmpty else { throw PackReadError.missingDeltaBase }
        var resolvedBytes = 0
        let resolved = try entries.map { entry -> ResolvedPackObject in
            guard let object = cache[entry.offset] else {
                throw PackReadError.missingDeltaBase
            }
            guard object.payload.count <= limits.maximumResolvedBytes - resolvedBytes else {
                throw PackReadError.resourceLimitExceeded
            }
            resolvedBytes += object.payload.count
            return ResolvedPackObject(
                offset: entry.offset,
                identifier: objectFormat.hash(object.canonicalBytes),
                object: object
            )
        }
        return PackFile(
            version: version,
            objectFormat: objectFormat,
            checksum: checksum,
            objects: resolved
        )
    }

    private static func readerOffsetAfterHeader(
        content: [UInt8],
        entryOffset: Int,
        compressedStart: Int
    ) -> Int {
        compressedStart - entryOffset
    }

    private static func resolve(
        _ entry: Entry,
        byOffset: [Int: Entry],
        byIdentifier: [[UInt8]: GitObject],
        externalBase: ExternalBaseResolver?,
        objectFormat: GitHashAlgorithm,
        cache: inout [Int: GitObject],
        visiting: Set<Int>,
        depth: Int,
        limits: PackLimits
    ) throws -> GitObject? {
        if let value = cache[entry.offset] { return value }
        guard depth <= limits.maximumDeltaDepth else {
            throw PackReadError.resourceLimitExceeded
        }
        guard !visiting.contains(entry.offset) else {
            throw PackReadError.cyclicDelta
        }
        switch entry.base {
        case .none(let type):
            let object = GitObject(type: type, payload: entry.data)
            cache[entry.offset] = object
            return object
        case .offset(let baseOffset):
            guard let baseEntry = byOffset[baseOffset] else {
                throw PackReadError.missingDeltaBase
            }
            var next = visiting
            next.insert(entry.offset)
            guard let base = try resolve(
                baseEntry,
                byOffset: byOffset,
                byIdentifier: byIdentifier,
                externalBase: externalBase,
                objectFormat: objectFormat,
                cache: &cache,
                visiting: next,
                depth: depth + 1,
                limits: limits
            ) else { return nil }
            let object = GitObject(
                type: base.type,
                payload: try applyDelta(base: base.payload, delta: entry.data, limit: limits.maximumObjectBytes)
            )
            cache[entry.offset] = object
            return object
        case .identifier(let identifier):
            let base: GitObject
            if let packed = byIdentifier[identifier] {
                base = packed
            } else if let resolved = try externalBase?(identifier) {
                guard objectFormat.hash(resolved.canonicalBytes) == identifier else {
                    throw PackReadError.missingDeltaBase
                }
                base = resolved
            } else {
                return nil
            }
            let object = GitObject(
                type: base.type,
                payload: try applyDelta(base: base.payload, delta: entry.data, limit: limits.maximumObjectBytes)
            )
            cache[entry.offset] = object
            return object
        }
    }

    private static func applyDelta(
        base: [UInt8],
        delta: [UInt8],
        limit: Int
    ) throws -> [UInt8] {
        var index = 0
        let sourceSize = try variableInteger(delta, index: &index)
        let targetSize = try variableInteger(delta, index: &index)
        guard sourceSize == base.count, targetSize <= limit else {
            throw PackReadError.deltaSizeMismatch
        }
        var output: [UInt8] = []
        output.reserveCapacity(targetSize)
        while index < delta.count {
            let command = delta[index]
            index += 1
            if command & 0x80 != 0 {
                var offset = 0
                var size = 0
                for bit in 0..<4 where command & (1 << bit) != 0 {
                    guard index < delta.count else { throw PackReadError.truncated }
                    offset |= Int(delta[index]) << (8 * bit)
                    index += 1
                }
                for bit in 0..<3 where command & (0x10 << bit) != 0 {
                    guard index < delta.count else { throw PackReadError.truncated }
                    size |= Int(delta[index]) << (8 * bit)
                    index += 1
                }
                if size == 0 { size = 0x10000 }
                guard offset >= 0, size >= 0, offset <= base.count - size,
                      output.count <= targetSize - size
                else { throw PackReadError.deltaSizeMismatch }
                output.append(contentsOf: base[offset..<(offset + size)])
            } else {
                let count = Int(command)
                guard count > 0, index <= delta.count - count,
                      output.count <= targetSize - count
                else { throw PackReadError.deltaSizeMismatch }
                output.append(contentsOf: delta[index..<(index + count)])
                index += count
            }
        }
        guard output.count == targetSize else { throw PackReadError.deltaSizeMismatch }
        return output
    }

    private static func variableInteger(
        _ bytes: [UInt8],
        index: inout Int
    ) throws -> Int {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw PackReadError.truncated }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        guard value <= UInt64(Int.max) else { throw PackReadError.resourceLimitExceeded }
        return Int(value)
    }
}
