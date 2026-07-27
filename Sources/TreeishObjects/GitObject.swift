import Foundation
import TreeishCore

public enum GitObjectType: String, Sendable, Hashable, Codable, CaseIterable {
    case blob
    case tree
    case commit
    case tag
}

public struct GitObject: Sendable, Hashable {
    public let type: GitObjectType
    public let payload: [UInt8]

    public init(type: GitObjectType, payload: [UInt8]) {
        self.type = type
        self.payload = payload
    }

    public var canonicalBytes: [UInt8] {
        Array("\(type.rawValue) \(payload.count)\0".utf8) + payload
    }

    public static func decodeCanonical(
        _ bytes: [UInt8],
        maximumPayloadBytes: Int
    ) throws -> GitObject {
        guard let nul = bytes.firstIndex(of: 0),
              let header = String(bytes: bytes[..<nul], encoding: .utf8)
        else {
            throw GitObjectError.invalidHeader
        }
        let components = header.split(separator: " ", omittingEmptySubsequences: false)
        guard components.count == 2,
              let type = GitObjectType(rawValue: String(components[0])),
              let declaredCount = Int(components[1]),
              declaredCount >= 0,
              declaredCount <= maximumPayloadBytes
        else {
            throw GitObjectError.invalidHeader
        }
        let payload = Array(bytes[bytes.index(after: nul)...])
        guard payload.count == declaredCount else {
            throw GitObjectError.sizeMismatch
        }
        return GitObject(type: type, payload: payload)
    }
}

public enum GitObjectError: Error, Sendable, Equatable {
    case invalidHeader
    case sizeMismatch
    case hashMismatch
    case objectNotFound
}
