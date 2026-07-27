import Foundation

public struct ReceivePackCommand: Sendable, Hashable {
    public let old: [UInt8]
    public let new: [UInt8]
    public let name: [UInt8]

    public init(old: [UInt8], new: [UInt8], name: [UInt8]) throws {
        guard old.count == 20, new.count == 20, !name.isEmpty else {
            throw ReceivePackError.invalidCommand
        }
        self.old = old
        self.new = new
        self.name = name
    }
}

public enum ReceivePackRefStatus: Sendable, Hashable {
    case accepted([UInt8])
    case rejected([UInt8], reason: String)
}

public struct ReceivePackResult: Sendable, Hashable {
    public let unpacked: Bool
    public let statuses: [ReceivePackRefStatus]
}

public enum ReceivePackError: Error, Sendable, Equatable {
    case invalidCommand
    case malformedStatus
    case unpackFailed(String)
    case remoteFatal(String)
}

public enum ReceivePackV0 {
    public static func request(
        commands: [ReceivePackCommand],
        pack: [UInt8],
        advertisedCapabilities: Set<String>
    ) throws -> [UInt8] {
        guard !commands.isEmpty else { throw ReceivePackError.invalidCommand }
        let supported = ["report-status-v2", "report-status", "side-band-64k", "ofs-delta", "atomic"]
        let selected = supported.filter(advertisedCapabilities.contains)
        var output: [UInt8] = []
        for (index, command) in commands.enumerated() {
            var line = "\(hex(command.old)) \(hex(command.new)) \(String(decoding: command.name, as: UTF8.self))"
            if index == 0, !selected.isEmpty {
                line += "\0" + selected.joined(separator: " ")
            }
            line += "\n"
            output += try PacketLineEncoder.encode(.data(Array(line.utf8)))
        }
        output += try PacketLineEncoder.encode(.flush)
        output += pack
        return output
    }

    public static func parseResponse(
        _ bytes: [UInt8],
        sideband: Bool
    ) throws -> ReceivePackResult {
        var decoder = PacketLineDecoder()
        let outer = try decoder.append(bytes)
        try decoder.finish()
        var statusBytes: [UInt8] = []
        for packet in outer {
            guard case .data(let payload) = packet else { continue }
            if sideband {
                switch try SidebandDecoder.decode(payload) {
                case .data(let value): statusBytes += value
                case .progress: continue
                case .fatal(let value):
                    throw ReceivePackError.remoteFatal(String(decoding: value, as: UTF8.self))
                }
            } else {
                statusBytes += try PacketLineEncoder.encode(.data(payload))
            }
        }
        var statusDecoder = PacketLineDecoder()
        let packets = try statusDecoder.append(statusBytes)
        try statusDecoder.finish()
        var unpacked = false
        var statuses: [ReceivePackRefStatus] = []
        for packet in packets {
            guard case .data(let payload) = packet else { continue }
            let line = String(decoding: payload, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            if line == "unpack ok" { unpacked = true }
            else if line.hasPrefix("unpack ") {
                throw ReceivePackError.unpackFailed(String(line.dropFirst(7)))
            } else if line.hasPrefix("ok ") {
                statuses.append(.accepted(Array(line.dropFirst(3).utf8)))
            } else if line.hasPrefix("ng ") {
                let remainder = line.dropFirst(3)
                let fields = remainder.split(separator: " ", maxSplits: 1)
                guard let name = fields.first else { throw ReceivePackError.malformedStatus }
                statuses.append(
                    .rejected(
                        Array(name.utf8),
                        reason: fields.count == 2 ? String(fields[1]) : "rejected"
                    )
                )
            }
        }
        guard unpacked else { throw ReceivePackError.malformedStatus }
        return ReceivePackResult(unpacked: true, statuses: statuses)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
