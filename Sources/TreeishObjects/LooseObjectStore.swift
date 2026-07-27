import Foundation
import TreeishCore
import TreeishFileSystem

public struct LooseObjectStore: Sendable {
    private let gitDirectory: RootDirectory
    private let limits: TreeishResourceLimits

    public init(
        gitDirectory: RootDirectory,
        limits: TreeishResourceLimits = .init()
    ) {
        self.gitDirectory = gitDirectory
        self.limits = limits
    }

    @discardableResult
    public func write(_ object: GitObject) throws -> [UInt8] {
        guard object.payload.count <= limits.maximumObjectBytes else {
            throw ZlibError.resourceLimitExceeded
        }
        let canonical = object.canonicalBytes
        let identifier = SHA1.hash(canonical)
        let hexadecimal = hexadecimalString(identifier)
        let components = [
            "objects",
            String(hexadecimal.prefix(2)),
            String(hexadecimal.dropFirst(2)),
        ]
        if try !gitDirectory.exists(components) {
            try gitDirectory.writeAtomically(
                Zlib.compress(canonical),
                to: components
            )
        }
        return identifier
    }

    public func read(identifier: [UInt8]) throws -> GitObject {
        guard identifier.count == 20 else {
            throw GitObjectError.objectNotFound
        }
        let hexadecimal = hexadecimalString(identifier)
        let compressed: [UInt8]
        do {
            compressed = try gitDirectory.read(
                [
                    "objects",
                    String(hexadecimal.prefix(2)),
                    String(hexadecimal.dropFirst(2)),
                ],
                limit: limits.maximumObjectBytes
            )
        } catch {
            throw GitObjectError.objectNotFound
        }
        let canonical = try Zlib.decompress(
            compressed,
            maximumOutputBytes: limits.maximumObjectBytes
        )
        guard SHA1.hash(canonical) == identifier else {
            throw GitObjectError.hashMismatch
        }
        return try GitObject.decodeCanonical(
            canonical,
            maximumPayloadBytes: limits.maximumObjectBytes
        )
    }

    private func hexadecimalString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
