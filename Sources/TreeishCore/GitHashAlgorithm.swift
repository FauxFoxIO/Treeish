import Foundation

public enum GitHashAlgorithm: String, Sendable, Hashable, Codable, CaseIterable {
    case sha1
    case sha256

    public var byteCount: Int {
        switch self {
        case .sha1: 20
        case .sha256: 32
        }
    }

    public func hash(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        switch self {
        case .sha1: SHA1.hash(bytes)
        case .sha256: SHA256.hash(bytes)
        }
    }
}
