import Foundation

public enum ByteCodingError: Error, Sendable, Equatable {
    case truncated
    case integerOverflow
    case invalidValue
}

public struct CheckedByteReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    public var remainingCount: Int { bytes.count - offset }

    public mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw ByteCodingError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func read(count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remainingCount else {
            throw ByteCodingError.truncated
        }
        let range = offset..<(offset + count)
        offset += count
        return bytes[range]
    }

    public mutating func readUInt32BE() throws -> UInt32 {
        let value = try read(count: 4)
        return value.reduce(into: UInt32.zero) { result, byte in
            result = (result << 8) | UInt32(byte)
        }
    }
}
public struct CheckedByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    public mutating func append<S: Sequence>(contentsOf values: S)
    where S.Element == UInt8 {
        bytes.append(contentsOf: values)
    }

    public mutating func appendUInt32BE(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }
}
