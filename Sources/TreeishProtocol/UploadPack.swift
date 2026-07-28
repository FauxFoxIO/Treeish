import Foundation
import TreeishCore

public struct AdvertisedReference: Sendable, Hashable {
    public let name: [UInt8]
    public let objectID: [UInt8]
    public let peeledObjectID: [UInt8]?
}

public struct UploadPackAdvertisement: Sendable, Hashable {
    public let references: [AdvertisedReference]
    public let capabilities: Set<String>
    public let symbolicHead: String?
}

public enum UploadPackError: Error, Sendable, Equatable {
    case malformedAdvertisement
    case invalidObjectID
    case remoteFatal(String)
    case missingPack
}

public enum UploadPackV0 {
    public static func parseAdvertisement(
        _ packets: [PacketLine]
    ) throws -> UploadPackAdvertisement {
        var references: [AdvertisedReference] = []
        var capabilities: Set<String> = []
        var symbolicHead: String?
        var first = true
        for packet in packets {
            guard case .data(let bytes) = packet else { continue }
            if bytes.starts(with: Array("# service=".utf8)) { continue }
            var line = bytes
            if line.last == 0x0a { line.removeLast() }
            let fields = line.split(separator: 0x20, maxSplits: 1)
            guard fields.count == 2 else { throw UploadPackError.malformedAdvertisement }
            let identifier = try decodeHex(fields[0])
            var nameAndCapabilities = Array(fields[1])
            if first, let nul = nameAndCapabilities.firstIndex(of: 0) {
                let values = String(
                    decoding: nameAndCapabilities[nameAndCapabilities.index(after: nul)...],
                    as: UTF8.self
                ).split(separator: " ").map(String.init)
                capabilities = Set(values)
                symbolicHead = values.first(where: { $0.hasPrefix("symref=HEAD:") })
                    .map { String($0.dropFirst("symref=HEAD:".count)) }
                nameAndCapabilities.removeSubrange(nul...)
            }
            first = false
            if nameAndCapabilities.suffix(3).elementsEqual(Array("^{}".utf8)),
               let prior = references.indices.last,
               references[prior].name == Array(nameAndCapabilities.dropLast(3)) {
                let value = references[prior]
                references[prior] = AdvertisedReference(
                    name: value.name,
                    objectID: value.objectID,
                    peeledObjectID: identifier
                )
            } else {
                references.append(
                    AdvertisedReference(
                        name: nameAndCapabilities,
                        objectID: identifier,
                        peeledObjectID: nil
                    )
                )
            }
        }
        return UploadPackAdvertisement(
            references: references,
            capabilities: capabilities,
            symbolicHead: symbolicHead
        )
    }

    public static func fetchRequest(
        wants: [[UInt8]],
        haves: [[UInt8]] = [],
        objectFormat: GitHashAlgorithm = .sha1,
        capabilities advertised: Set<String>
    ) throws -> [UInt8] {
        guard !wants.isEmpty else { throw UploadPackError.invalidObjectID }
        var supported = [
            "multi_ack_detailed", "side-band-64k", "ofs-delta", "include-tag",
        ]
        let objectCapability = "object-format=\(objectFormat.rawValue)"
        if advertised.contains(objectCapability) {
            supported.append(objectCapability)
        } else if objectFormat != .sha1 {
            throw UploadPackError.invalidObjectID
        }
        let selected = supported.filter(advertised.contains)
        var output: [UInt8] = []
        for (index, identifier) in wants.enumerated() {
            guard identifier.count == objectFormat.byteCount else {
                throw UploadPackError.invalidObjectID
            }
            let suffix = index == 0 && !selected.isEmpty
                ? " " + selected.joined(separator: " ")
                : ""
            output += try PacketLineEncoder.encode(
                .data(Array("want \(hex(identifier))\(suffix)\n".utf8))
            )
        }
        output += try PacketLineEncoder.encode(.flush)
        for identifier in haves {
            guard identifier.count == objectFormat.byteCount else {
                throw UploadPackError.invalidObjectID
            }
            output += try PacketLineEncoder.encode(
                .data(Array("have \(hex(identifier))\n".utf8))
            )
        }
        output += try PacketLineEncoder.encode(.data(Array("done\n".utf8)))
        return output
    }

    public static func parseFetchResponse(_ bytes: [UInt8]) throws -> [UInt8] {
        var decoder = PacketLineDecoder()
        let packets = try decoder.append(bytes)
        try decoder.finish()
        var pack: [UInt8] = []
        for packet in packets {
            guard case .data(let payload) = packet else { continue }
            if payload == Array("NAK\n".utf8) || payload.starts(with: Array("ACK ".utf8)) {
                continue
            }
            let sideband = try SidebandDecoder.decode(payload)
            switch sideband {
            case .data(let value): pack.append(contentsOf: value)
            case .progress: continue
            case .fatal(let value):
                throw UploadPackError.remoteFatal(String(decoding: value, as: UTF8.self))
            }
        }
        guard pack.starts(with: Array("PACK".utf8)) else {
            throw UploadPackError.missingPack
        }
        return pack
    }

    private static func decodeHex(_ bytes: ArraySlice<UInt8>) throws -> [UInt8] {
        guard bytes.count == 40 || bytes.count == 64 else {
            throw UploadPackError.invalidObjectID
        }
        var output: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let next = bytes.index(index, offsetBy: 2)
            guard let byte = UInt8(String(decoding: bytes[index..<next], as: UTF8.self), radix: 16) else {
                throw UploadPackError.invalidObjectID
            }
            output.append(byte)
            index = next
        }
        return output
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct UploadPackV2Capabilities: Sendable, Hashable {
    public let values: [String: String?]

    public init(values: [String: String?]) { self.values = values }
    public func supports(_ name: String) -> Bool { values.keys.contains(name) }

    public var objectFormat: GitHashAlgorithm {
        guard let value = values["object-format"] ?? nil else {
            return .sha1
        }
        return GitHashAlgorithm(rawValue: value) ?? .sha1
    }
}

public enum UploadPackV2 {
    public static func parseCapabilities(_ packets: [PacketLine]) throws -> UploadPackV2Capabilities {
        var sawVersion = false
        var values: [String: String?] = [:]
        for packet in packets {
            guard case .data(var bytes) = packet else { continue }
            if bytes.last == 0x0a { bytes.removeLast() }
            let line = String(decoding: bytes, as: UTF8.self)
            if line.hasPrefix("# service=") { continue }
            if !sawVersion {
                guard line == "version 2" else { throw UploadPackError.malformedAdvertisement }
                sawVersion = true
                continue
            }
            let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = fields.first, !name.isEmpty else {
                throw UploadPackError.malformedAdvertisement
            }
            values[String(name)] = fields.count == 2 ? String(fields[1]) : nil
        }
        guard sawVersion else { throw UploadPackError.malformedAdvertisement }
        return UploadPackV2Capabilities(values: values)
    }

    public static func lsRefsRequest(
        prefixes: [[UInt8]] = [],
        objectFormat: GitHashAlgorithm = .sha1,
        capabilities: UploadPackV2Capabilities
    ) throws -> [UInt8] {
        guard capabilities.supports("ls-refs") else {
            throw UploadPackError.malformedAdvertisement
        }
        var output = try PacketLineEncoder.encode(.data(Array("command=ls-refs\n".utf8)))
        if capabilities.supports("object-format") {
            guard capabilities.objectFormat == objectFormat else {
                throw UploadPackError.invalidObjectID
            }
            output += try PacketLineEncoder.encode(
                .data(Array("object-format=\(objectFormat.rawValue)\n".utf8))
            )
        }
        output += try PacketLineEncoder.encode(.delimiter)
        output += try PacketLineEncoder.encode(.data(Array("peel\n".utf8)))
        output += try PacketLineEncoder.encode(.data(Array("symrefs\n".utf8)))
        for prefix in prefixes {
            guard !prefix.contains(0), !prefix.contains(0x0a) else {
                throw UploadPackError.malformedAdvertisement
            }
            output += try PacketLineEncoder.encode(.data(Array("ref-prefix ".utf8) + prefix + [0x0a]))
        }
        output += try PacketLineEncoder.encode(.flush)
        return output
    }

    public static func parseLsRefs(_ packets: [PacketLine]) throws -> UploadPackAdvertisement {
        var references: [AdvertisedReference] = []
        var symbolicHead: String?
        for packet in packets {
            guard case .data(var bytes) = packet else { continue }
            if bytes.last == 0x0a { bytes.removeLast() }
            let fields = bytes.split(separator: 0x20)
            guard fields.count >= 2 else { throw UploadPackError.malformedAdvertisement }
            let objectID = try decodeHexV2(fields[0])
            let name = Array(fields[1])
            var peeled: [UInt8]?
            for attribute in fields.dropFirst(2) {
                if attribute.starts(with: Array("peeled:".utf8)) {
                    peeled = try decodeHexV2(attribute.dropFirst(7))
                } else if name == Array("HEAD".utf8),
                          attribute.starts(with: Array("symref-target:".utf8)) {
                    symbolicHead = String(decoding: attribute.dropFirst(14), as: UTF8.self)
                }
            }
            references.append(AdvertisedReference(name: name, objectID: objectID, peeledObjectID: peeled))
        }
        return UploadPackAdvertisement(
            references: references,
            capabilities: [],
            symbolicHead: symbolicHead
        )
    }

    public static func fetchRequest(
        wants: [[UInt8]],
        haves: [[UInt8]] = [],
        objectFormat: GitHashAlgorithm = .sha1,
        capabilities: UploadPackV2Capabilities
    ) throws -> [UInt8] {
        guard !wants.isEmpty, capabilities.supports("fetch") else {
            throw UploadPackError.invalidObjectID
        }
        var output = try PacketLineEncoder.encode(.data(Array("command=fetch\n".utf8)))
        if capabilities.supports("object-format") {
            guard capabilities.objectFormat == objectFormat else {
                throw UploadPackError.invalidObjectID
            }
            output += try PacketLineEncoder.encode(
                .data(Array("object-format=\(objectFormat.rawValue)\n".utf8))
            )
        }
        output += try PacketLineEncoder.encode(.delimiter)
        output += try PacketLineEncoder.encode(.data(Array("thin-pack\n".utf8)))
        output += try PacketLineEncoder.encode(.data(Array("ofs-delta\n".utf8)))
        for identifier in wants {
            guard identifier.count == objectFormat.byteCount else {
                throw UploadPackError.invalidObjectID
            }
            output += try PacketLineEncoder.encode(.data(Array("want \(hexV2(identifier))\n".utf8)))
        }
        for identifier in haves {
            guard identifier.count == objectFormat.byteCount else {
                throw UploadPackError.invalidObjectID
            }
            output += try PacketLineEncoder.encode(.data(Array("have \(hexV2(identifier))\n".utf8)))
        }
        output += try PacketLineEncoder.encode(.data(Array("done\n".utf8)))
        output += try PacketLineEncoder.encode(.flush)
        return output
    }

    public static func parseFetchResponse(_ packets: [PacketLine]) throws -> [UInt8] {
        var inPackfile = false
        var pack: [UInt8] = []
        for packet in packets {
            switch packet {
            case .data(let payload):
                if payload == Array("packfile\n".utf8) { inPackfile = true; continue }
                guard inPackfile else { continue }
                switch try SidebandDecoder.decode(payload) {
                case .data(let bytes): pack += bytes
                case .progress: continue
                case .fatal(let bytes):
                    throw UploadPackError.remoteFatal(String(decoding: bytes, as: UTF8.self))
                }
            case .delimiter, .responseEnd, .flush:
                continue
            }
        }
        guard pack.starts(with: Array("PACK".utf8)) else { throw UploadPackError.missingPack }
        return pack
    }
}

private func decodeHexV2<S: Collection>(_ bytes: S) throws -> [UInt8] where S.Element == UInt8 {
    guard bytes.count == 40 || bytes.count == 64 else {
        throw UploadPackError.invalidObjectID
    }
    let values = Array(bytes)
    var output: [UInt8] = []
    for index in stride(from: 0, to: values.count, by: 2) {
        guard let byte = UInt8(String(decoding: values[index..<(index + 2)], as: UTF8.self), radix: 16) else {
            throw UploadPackError.invalidObjectID
        }
        output.append(byte)
    }
    return output
}

private func hexV2(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
