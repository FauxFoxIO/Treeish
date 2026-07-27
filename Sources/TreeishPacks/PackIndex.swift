import Foundation
import TreeishCore

public struct PackIndexEntry: Sendable, Hashable {
    public let identifier: [UInt8]
    public let crc32: UInt32
    public let offset: UInt64
}

public struct PackIndexV2: Sendable, Hashable {
    public let entries: [PackIndexEntry]
    public let packChecksum: [UInt8]

    public static func read(_ bytes: [UInt8]) throws -> PackIndexV2 {
        guard bytes.count >= 8 + 256 * 4 + 40,
              SHA1.hash(Array(bytes.dropLast(20))) == Array(bytes.suffix(20)) else {
            throw PackReadError.checksumMismatch
        }
        var reader = CheckedByteReader(Array(bytes.dropLast(20)))
        guard Array(try reader.read(count: 4)) == [0xff, 0x74, 0x4f, 0x63] else {
            throw PackReadError.invalidSignature
        }
        guard try reader.readUInt32BE() == 2 else {
            throw PackReadError.unsupportedVersion(0)
        }
        var fanout: [UInt32] = []
        fanout.reserveCapacity(256)
        var previous: UInt32 = 0
        for _ in 0..<256 {
            let value = try reader.readUInt32BE()
            guard value >= previous else { throw PackReadError.indexMismatch }
            fanout.append(value)
            previous = value
        }
        let count = Int(fanout[255])
        guard count <= 10_000_000 else { throw PackReadError.resourceLimitExceeded }
        var identifiers: [[UInt8]] = []
        identifiers.reserveCapacity(count)
        for _ in 0..<count { identifiers.append(Array(try reader.read(count: 20))) }
        guard zip(identifiers, identifiers.dropFirst()).allSatisfy({
            $0.lexicographicallyPrecedes($1)
        }) else { throw PackReadError.indexMismatch }
        var crcs: [UInt32] = []
        crcs.reserveCapacity(count)
        for _ in 0..<count { crcs.append(try reader.readUInt32BE()) }
        var offsets: [UInt32] = []
        offsets.reserveCapacity(count)
        var largeCount = 0
        for _ in 0..<count {
            let value = try reader.readUInt32BE()
            offsets.append(value)
            if value & 0x8000_0000 != 0 {
                largeCount = max(largeCount, Int(value & 0x7fff_ffff) + 1)
            }
        }
        var largeOffsets: [UInt64] = []
        largeOffsets.reserveCapacity(largeCount)
        for _ in 0..<largeCount {
            let high = UInt64(try reader.readUInt32BE())
            let low = UInt64(try reader.readUInt32BE())
            largeOffsets.append(high << 32 | low)
        }
        let packChecksum = Array(try reader.read(count: 20))
        guard reader.remainingCount == 0 else { throw PackReadError.indexMismatch }
        let entries = try identifiers.indices.map { index -> PackIndexEntry in
            let encoded = offsets[index]
            let offset: UInt64
            if encoded & 0x8000_0000 == 0 {
                offset = UInt64(encoded)
            } else {
                let largeIndex = Int(encoded & 0x7fff_ffff)
                guard largeOffsets.indices.contains(largeIndex) else {
                    throw PackReadError.indexMismatch
                }
                offset = largeOffsets[largeIndex]
            }
            return PackIndexEntry(
                identifier: identifiers[index],
                crc32: crcs[index],
                offset: offset
            )
        }
        return PackIndexV2(entries: entries, packChecksum: packChecksum)
    }

    public func contains(_ identifier: [UInt8]) -> Bool {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].identifier == identifier { return true }
            if entries[middle].identifier.lexicographicallyPrecedes(identifier) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return false
    }
}
