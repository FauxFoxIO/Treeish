import Foundation
import TreeishCore

public struct MultiPackIndexEntry: Sendable, Hashable {
    public let identifier: [UInt8]
    public let packName: String
    public let offset: UInt64
}

public struct MultiPackIndex: Sendable, Hashable {
    public let version: UInt8
    public let objectFormat: GitHashAlgorithm
    public let packNames: [String]
    public let entries: [MultiPackIndexEntry]

    public static func read(
        _ bytes: [UInt8],
        objectFormat: GitHashAlgorithm
    ) throws -> MultiPackIndex {
        let hashLength = objectFormat.byteCount
        guard bytes.count >= 12 + 12 + hashLength,
              objectFormat.hash(Array(bytes.dropLast(hashLength)))
                == Array(bytes.suffix(hashLength))
        else { throw PackReadError.checksumMismatch }
        let contentEnd = bytes.count - hashLength
        guard Array(bytes[0..<4]) == Array("MIDX".utf8) else {
            throw PackReadError.invalidSignature
        }
        let version = bytes[4]
        guard version == 1 || version == 2 else {
            throw PackReadError.unsupportedVersion(UInt32(version))
        }
        let objectIDVersion = bytes[5]
        guard (objectIDVersion == 1 && objectFormat == .sha1)
                || (objectIDVersion == 2 && objectFormat == .sha256)
        else { throw PackReadError.indexMismatch }
        let chunkCount = Int(bytes[6])
        let baseCount = Int(bytes[7])
        guard chunkCount > 0, chunkCount <= 32, baseCount == 0 else {
            throw PackReadError.unsupportedVersion(UInt32(version))
        }
        let packCount = Int(try readUInt32(bytes, at: 8))
        guard packCount <= 1_000_000 else {
            throw PackReadError.resourceLimitExceeded
        }
        let lookupEnd = 12 + (chunkCount + 1) * 12
        guard lookupEnd <= contentEnd else { throw ByteCodingError.truncated }
        var chunks: [String: Range<Int>] = [:]
        var descriptors: [(id: [UInt8], offset: Int)] = []
        for index in 0...chunkCount {
            let position = 12 + index * 12
            let identifier = Array(bytes[position..<(position + 4)])
            let offset64 = try readUInt64(bytes, at: position + 4)
            guard let offset = Int(exactly: offset64),
                  offset >= lookupEnd,
                  offset <= contentEnd else {
                throw PackReadError.indexMismatch
            }
            descriptors.append((identifier, offset))
        }
        guard descriptors.last?.id == [0, 0, 0, 0],
              zip(descriptors, descriptors.dropFirst()).allSatisfy({
                  $0.offset <= $1.offset
              })
        else { throw PackReadError.indexMismatch }
        for index in 0..<chunkCount {
            let id = String(decoding: descriptors[index].id, as: UTF8.self)
            guard chunks[id] == nil else { throw PackReadError.indexMismatch }
            chunks[id] = descriptors[index].offset..<descriptors[index + 1].offset
        }
        guard let namesRange = chunks["PNAM"],
              let fanoutRange = chunks["OIDF"],
              let identifiersRange = chunks["OIDL"],
              let offsetsRange = chunks["OOFF"],
              fanoutRange.count == 256 * 4
        else { throw PackReadError.indexMismatch }

        let names = try parsePackNames(
            bytes[namesRange],
            expectedCount: packCount
        )
        var fanout: [UInt32] = []
        var previous: UInt32 = 0
        for index in 0..<256 {
            let value = try readUInt32(
                bytes,
                at: fanoutRange.lowerBound + index * 4
            )
            guard value >= previous else {
                throw PackReadError.indexMismatch
            }
            fanout.append(value)
            previous = value
        }
        let objectCount = Int(fanout[255])
        guard objectCount <= 10_000_000,
              identifiersRange.count == objectCount * hashLength,
              offsetsRange.count == objectCount * 8
        else { throw PackReadError.resourceLimitExceeded }
        var identifiers: [[UInt8]] = []
        identifiers.reserveCapacity(objectCount)
        for index in 0..<objectCount {
            let start = identifiersRange.lowerBound + index * hashLength
            identifiers.append(Array(bytes[start..<(start + hashLength)]))
        }
        guard zip(identifiers, identifiers.dropFirst()).allSatisfy({
            $0.lexicographicallyPrecedes($1)
        }) else { throw PackReadError.indexMismatch }

        let largeRange = chunks["LOFF"]
        var entries: [MultiPackIndexEntry] = []
        entries.reserveCapacity(objectCount)
        for index in 0..<objectCount {
            let start = offsetsRange.lowerBound + index * 8
            let packID = Int(try readUInt32(bytes, at: start))
            let encoded = try readUInt32(bytes, at: start + 4)
            guard names.indices.contains(packID) else {
                throw PackReadError.indexMismatch
            }
            let offset: UInt64
            if encoded & 0x8000_0000 == 0 {
                offset = UInt64(encoded)
            } else {
                guard let largeRange else {
                    throw PackReadError.indexMismatch
                }
                let largeIndex = Int(encoded & 0x7fff_ffff)
                let position = largeRange.lowerBound + largeIndex * 8
                guard position <= largeRange.upperBound - 8 else {
                    throw PackReadError.indexMismatch
                }
                offset = try readUInt64(bytes, at: position)
            }
            entries.append(MultiPackIndexEntry(
                identifier: identifiers[index],
                packName: names[packID],
                offset: offset
            ))
        }
        return MultiPackIndex(
            version: version,
            objectFormat: objectFormat,
            packNames: names,
            entries: entries
        )
    }

    public func entry(for identifier: [UInt8]) -> MultiPackIndexEntry? {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let value = entries[middle]
            if value.identifier == identifier { return value }
            if value.identifier.lexicographicallyPrecedes(identifier) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return nil
    }

    private static func parsePackNames(
        _ bytes: ArraySlice<UInt8>,
        expectedCount: Int
    ) throws -> [String] {
        var names: [String] = []
        var start = bytes.startIndex
        while start < bytes.endIndex, names.count < expectedCount {
            guard let end = bytes[start...].firstIndex(of: 0) else {
                throw PackReadError.indexMismatch
            }
            let value = bytes[start..<end]
            guard let name = String(bytes: value, encoding: .utf8),
                  name.hasSuffix(".idx"),
                  !name.contains("/"),
                  !name.contains("\\"),
                  !name.isEmpty else {
                throw PackReadError.indexMismatch
            }
            names.append(name)
            start = bytes.index(after: end)
        }
        guard names.count == expectedCount,
              bytes[start...].allSatisfy({ $0 == 0 }) else {
            throw PackReadError.indexMismatch
        }
        return names
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else {
            throw ByteCodingError.truncated
        }
        return bytes[offset..<(offset + 4)].reduce(into: UInt32.zero) {
            $0 = ($0 << 8) | UInt32($1)
        }
    }

    private static func readUInt64(
        _ bytes: [UInt8],
        at offset: Int
    ) throws -> UInt64 {
        guard offset >= 0, offset <= bytes.count - 8 else {
            throw ByteCodingError.truncated
        }
        return bytes[offset..<(offset + 8)].reduce(into: UInt64.zero) {
            $0 = ($0 << 8) | UInt64($1)
        }
    }
}
