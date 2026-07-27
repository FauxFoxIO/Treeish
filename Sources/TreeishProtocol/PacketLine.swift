import Foundation
import TreeishCore

public enum PacketLine: Sendable, Hashable {
    case data([UInt8])
    case flush
    case delimiter
    case responseEnd
}

public enum PacketLineError: Error, Sendable, Equatable {
    case truncated
    case invalidLength
    case packetTooLarge
    case invalidSideband
}

public struct PacketLineDecoder: Sendable {
    private var buffer: [UInt8] = []
    public var maximumPacketBytes: Int

    public init(maximumPacketBytes: Int = 65_520) {
        self.maximumPacketBytes = maximumPacketBytes
    }

    public mutating func append(_ bytes: some Sequence<UInt8>) throws -> [PacketLine] {
        buffer.append(contentsOf: bytes)
        var packets: [PacketLine] = []
        while buffer.count >= 4 {
            guard let text = String(bytes: buffer.prefix(4), encoding: .ascii),
                  let length = Int(text, radix: 16)
            else { throw PacketLineError.invalidLength }
            switch length {
            case 0:
                buffer.removeFirst(4)
                packets.append(.flush)
            case 1:
                buffer.removeFirst(4)
                packets.append(.delimiter)
            case 2:
                buffer.removeFirst(4)
                packets.append(.responseEnd)
            case 3:
                throw PacketLineError.invalidLength
            default:
                guard length <= maximumPacketBytes else {
                    throw PacketLineError.packetTooLarge
                }
                guard buffer.count >= length else { return packets }
                packets.append(.data(Array(buffer[4..<length])))
                buffer.removeFirst(length)
            }
        }
        return packets
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw PacketLineError.truncated }
    }
}

public enum PacketLineEncoder {
    public static func encode(_ packet: PacketLine) throws -> [UInt8] {
        switch packet {
        case .flush: return Array("0000".utf8)
        case .delimiter: return Array("0001".utf8)
        case .responseEnd: return Array("0002".utf8)
        case .data(let payload):
            let length = payload.count + 4
            guard length <= 65_520 else { throw PacketLineError.packetTooLarge }
            return Array(String(format: "%04x", length).utf8) + payload
        }
    }
}

public enum SidebandEvent: Sendable, Hashable {
    case data([UInt8])
    case progress([UInt8])
    case fatal([UInt8])
}

public enum SidebandDecoder {
    public static func decode(_ payload: [UInt8]) throws -> SidebandEvent {
        guard let channel = payload.first else { throw PacketLineError.invalidSideband }
        let body = Array(payload.dropFirst())
        switch channel {
        case 1: return .data(body)
        case 2: return .progress(body)
        case 3: return .fatal(body)
        default: throw PacketLineError.invalidSideband
        }
    }
}

public struct ProtocolV2Advertisement: Sendable, Hashable {
    public let version: Int
    public let capabilities: [String: [String]]

    public init(packets: [PacketLine]) throws {
        var lines: [String] = []
        for packet in packets {
            if case .data(let bytes) = packet {
                lines.append(String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .newlines))
            }
        }
        guard lines.first == "version 2" else {
            throw PacketLineError.invalidLength
        }
        version = 2
        var values: [String: [String]] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: "=", maxSplits: 1)
            let name = String(pieces[0])
            let arguments = pieces.count == 2
                ? pieces[1].split(separator: " ").map(String.init)
                : []
            values[name] = arguments
        }
        capabilities = values
    }
}
