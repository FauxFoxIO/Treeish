import Foundation
import TreeishCore
import TreeishObjects

public struct PackObject: Sendable, Hashable {
    public let identifier: [UInt8]
    public let object: GitObject

    public init(identifier: [UInt8], object: GitObject) throws {
        guard let algorithm = GitHashAlgorithm.allCases.first(where: {
            $0.byteCount == identifier.count
        }),
              algorithm.hash(object.canonicalBytes) == identifier
        else { throw PackError.invalidObject }
        self.identifier = identifier
        self.object = object
    }
}

public struct PackArchive: Sendable, Hashable {
    public let pack: [UInt8]
    public let index: [UInt8]
    public let checksum: [UInt8]
}

public enum PackError: Error, Sendable, Equatable {
    case invalidObject
    case tooManyObjects
    case offsetOverflow
}

public enum PackWriter {
    public static func write(
        _ objects: [PackObject],
        objectFormat: GitHashAlgorithm = .sha1
    ) throws -> PackArchive {
        guard objects.count <= Int(UInt32.max) else { throw PackError.tooManyObjects }
        guard objects.allSatisfy({
            $0.identifier.count == objectFormat.byteCount
        }) else { throw PackError.invalidObject }
        var pack = Array("PACK".utf8)
        appendUInt32(2, to: &pack)
        appendUInt32(UInt32(objects.count), to: &pack)
        var records: [(id: [UInt8], offset: UInt32, crc: UInt32)] = []
        for value in objects {
            guard pack.count <= Int(UInt32.max) else { throw PackError.offsetOverflow }
            let offset = UInt32(pack.count)
            let start = pack.count
            pack.append(contentsOf: header(
                type: typeCode(value.object.type),
                size: value.object.payload.count
            ))
            pack.append(contentsOf: try Zlib.compress(value.object.payload))
            records.append((value.identifier, offset, CRC32.hash(pack[start...])))
        }
        let checksum = objectFormat.hash(pack)
        pack.append(contentsOf: checksum)
        return PackArchive(
            pack: pack,
            index: makeIndex(
                records: records,
                packChecksum: checksum,
                objectFormat: objectFormat
            ),
            checksum: checksum
        )
    }

    private static func header(type: UInt8, size: Int) -> [UInt8] {
        var remaining = UInt64(size)
        var first = UInt8(remaining & 0x0f) | type << 4
        remaining >>= 4
        var bytes: [UInt8] = []
        if remaining != 0 { first |= 0x80 }
        bytes.append(first)
        while remaining != 0 {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        }
        return bytes
    }

    private static func typeCode(_ type: GitObjectType) -> UInt8 {
        switch type {
        case .commit: 1
        case .tree: 2
        case .blob: 3
        case .tag: 4
        }
    }

    private static func makeIndex(
        records: [(id: [UInt8], offset: UInt32, crc: UInt32)],
        packChecksum: [UInt8],
        objectFormat: GitHashAlgorithm
    ) -> [UInt8] {
        let sorted = records.sorted { $0.id.lexicographicallyPrecedes($1.id) }
        var result: [UInt8] = [0xff, 0x74, 0x4f, 0x63]
        appendUInt32(2, to: &result)
        var position = 0
        for prefix in 0...255 {
            while position < sorted.count, Int(sorted[position].id[0]) <= prefix {
                position += 1
            }
            appendUInt32(UInt32(position), to: &result)
        }
        for record in sorted { result.append(contentsOf: record.id) }
        for record in sorted { appendUInt32(record.crc, to: &result) }
        for record in sorted { appendUInt32(record.offset, to: &result) }
        result.append(contentsOf: packChecksum)
        result.append(contentsOf: objectFormat.hash(result))
        return result
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }
}

private enum CRC32 {
    static func hash(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320)
            }
        }
        return crc ^ 0xffff_ffff
    }
}
