import Foundation
import TreeishCore

public enum TreeishError: Error, Sendable, Equatable {
    case invalidPath
    case pathEncodingUnsupported
    case invalidRefName
    case invalidObjectID
    case repositoryNotFound
    case unsupportedRepositoryFormat(String)
    case unsupportedRequiredExtension(String)
    case mutationDisabled(CapabilityReason)
    case referenceNotFound
    case referenceChanged
    case symbolicReferenceLoop
    case malformedReference
    case remoteTransportUnavailable(GitRemoteTransport)
    case recoveryRequired(String)
    case indeterminateRemoteResult(String)
    case worktreeCollision(GitPath)
    case ignoredPath(GitPath)
    case pathOutsideSparseCheckout(GitPath)
    case unsupportedSubmoduleUpdate(GitPath, String)
    case submoduleRecursionLimitExceeded
    case unsupportedContentConversion(GitPath, String)
    case signingUnavailable
    case invalidSignature
    case invalidConfiguration
}

public struct GitPath: Sendable, Hashable, Codable {
    public static let root = GitPath(validatedBytes: [])

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard !bytes.contains(0),
              bytes.first != 0x2f,
              bytes.last != 0x2f
        else {
            throw TreeishError.invalidPath
        }
        if !bytes.isEmpty {
            let components = bytes.split(
                separator: 0x2f,
                omittingEmptySubsequences: false
            )
            guard components.allSatisfy({
                !$0.isEmpty && $0 != [0x2e] && $0 != [0x2e, 0x2e]
            }) else {
                throw TreeishError.invalidPath
            }
        }
        self.bytes = bytes
    }

    private init(validatedBytes: [UInt8]) {
        bytes = validatedBytes
    }

    public init(_ path: String) throws {
        try self.init(bytes: Array(path.utf8))
    }

    public var displayString: String {
        bytes.map { byte in
            if byte >= 0x20, byte < 0x7f, byte != 0x5c {
                return String(UnicodeScalar(byte))
            }
            return String(format: "\\x%02x", byte)
        }.joined()
    }

    internal var components: [String] {
        get throws {
            guard let string = String(bytes: bytes, encoding: .utf8) else {
                throw TreeishError.pathEncodingUnsupported
            }
            if string.isEmpty { return [] }
            return string.split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
        }
    }
}

public struct GitPathspec: Sendable, Hashable, Codable {
    public let pattern: [UInt8]
    public let isTop: Bool
    public let isLiteral: Bool
    public let isCaseInsensitive: Bool
    public let isExcluded: Bool

    public init(_ expression: String) throws {
        var value = expression
        var top = false
        var literal = false
        var glob = false
        var insensitive = false
        var excluded = false
        if value.hasPrefix(":(") {
            guard let end = value.firstIndex(of: ")") else {
                throw TreeishError.invalidPath
            }
            let magic = value[value.index(value.startIndex, offsetBy: 2)..<end]
            for component in magic.split(separator: ",").map(String.init) {
                switch component {
                case "top": top = true
                case "literal": literal = true
                case "glob": glob = true
                case "icase": insensitive = true
                case "exclude": excluded = true
                default: throw TreeishError.invalidPath
                }
            }
            value = String(value[value.index(after: end)...])
        } else if value.hasPrefix(":/") {
            top = true
            value.removeFirst(2)
        } else if value.hasPrefix(":!") || value.hasPrefix(":^") {
            excluded = true
            value.removeFirst(2)
        }
        guard !value.isEmpty, !value.contains("\u{0}"), !value.hasPrefix("/"),
              !(literal && glob) else {
            throw TreeishError.invalidPath
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw TreeishError.invalidPath
        }
        pattern = Array(value.utf8)
        isTop = top
        isLiteral = literal
        isCaseInsensitive = insensitive
        isExcluded = excluded
    }

    public init(literal path: GitPath) {
        pattern = path.bytes
        isTop = true
        isLiteral = true
        isCaseInsensitive = false
        isExcluded = false
    }

    public func matches(_ path: GitPath) -> Bool {
        if isLiteral {
            if isCaseInsensitive,
               let lhs = String(bytes: path.bytes, encoding: .utf8),
               let rhs = String(bytes: pattern, encoding: .utf8) {
                return lhs.caseInsensitiveCompare(rhs) == .orderedSame
                    || lhs.lowercased().hasPrefix(rhs.lowercased() + "/")
            }
            return path.bytes == pattern
                || path.bytes.starts(with: pattern + [0x2f])
        }
        guard let value = String(bytes: path.bytes, encoding: .utf8),
              let pattern = String(bytes: pattern, encoding: .utf8),
              let expression = try? NSRegularExpression(
                  pattern: Self.regularExpression(pattern, top: isTop),
                  options: isCaseInsensitive ? [.caseInsensitive] : []
              ) else {
            return false
        }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) != nil
    }

    public static func select(
        _ paths: some Sequence<GitPath>,
        using pathspecs: [GitPathspec]
    ) -> [GitPath] {
        guard !pathspecs.isEmpty else { return Array(paths) }
        let positive = pathspecs.filter { !$0.isExcluded }
        let negative = pathspecs.filter(\.isExcluded)
        return paths.filter { path in
            let included = positive.isEmpty || positive.contains { $0.matches(path) }
            return included && !negative.contains { $0.matches(path) }
        }
    }

    private static func regularExpression(_ pattern: String, top: Bool) -> String {
        var body = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let after = pattern.index(after: next)
                    if after < pattern.endIndex, pattern[after] == "/" {
                        body += "(?:.*/)?"
                        index = pattern.index(after: after)
                    } else {
                        body += ".*"
                        index = after
                    }
                } else {
                    body += "[^/]*"
                    index = next
                }
                continue
            }
            if character == "?" {
                body += "[^/]"
            } else if character == "[" {
                if let end = pattern[index...].firstIndex(of: "]") {
                    body += String(pattern[index...end])
                    index = pattern.index(after: end)
                    continue
                } else {
                    body += "\\["
                }
            } else {
                body += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        let prefix = top || pattern.contains("/") ? "^" : "^(?:.*/)?"
        return prefix + body + "(?:/.*)?$"
    }
}

public struct RefName: Sendable, Hashable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(validating bytes: [UInt8]) throws {
        guard !bytes.isEmpty,
              !bytes.contains(0),
              !bytes.contains(0x20),
              !bytes.contains(0x7f),
              !bytes.starts(with: [0x2f]),
              !bytes.suffix(1).elementsEqual([0x2f]),
              !Self.contains(bytes, sequence: Array("..".utf8)),
              !Self.contains(bytes, sequence: Array("@{".utf8)),
              !bytes.contains(0x5c),
              !bytes.contains(0x3a),
              !bytes.contains(0x3f),
              !bytes.contains(0x2a),
              !bytes.contains(0x5b)
        else {
            throw TreeishError.invalidRefName
        }
        let components = bytes.split(separator: 0x2f, omittingEmptySubsequences: false)
        guard components.allSatisfy({
            !$0.isEmpty &&
            !$0.starts(with: [0x2e]) &&
            !$0.suffix(5).elementsEqual(Array(".lock".utf8))
        }) else {
            throw TreeishError.invalidRefName
        }
        self.bytes = bytes
    }

    public init(_ name: String) throws {
        try self.init(validating: Array(name.utf8))
    }

    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }

    private static func contains(_ source: [UInt8], sequence: [UInt8]) -> Bool {
        guard !sequence.isEmpty, source.count >= sequence.count else { return false }
        return source.indices.dropLast(sequence.count - 1).contains { index in
            source[index..<(index + sequence.count)].elementsEqual(sequence)
        }
    }
}

public typealias ObjectHashAlgorithm = GitHashAlgorithm

public struct ObjectID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let algorithm: ObjectHashAlgorithm
    public let bytes: [UInt8]

    public init(algorithm: ObjectHashAlgorithm, bytes: [UInt8]) throws {
        guard bytes.count == algorithm.byteCount else {
            throw TreeishError.invalidObjectID
        }
        self.algorithm = algorithm
        self.bytes = bytes
    }

    public init(bytes: [UInt8]) throws {
        guard let algorithm = ObjectHashAlgorithm.allCases.first(where: {
            $0.byteCount == bytes.count
        }) else { throw TreeishError.invalidObjectID }
        try self.init(algorithm: algorithm, bytes: bytes)
    }

    public init(
        hex: String,
        algorithm: ObjectHashAlgorithm? = nil
    ) throws {
        guard let resolvedAlgorithm = algorithm ??
                ObjectHashAlgorithm.allCases.first(where: {
                    $0.byteCount * 2 == hex.utf8.count
                }),
              hex.utf8.count == resolvedAlgorithm.byteCount * 2 else {
            throw TreeishError.invalidObjectID
        }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(resolvedAlgorithm.byteCount)
        var index = hex.startIndex
        for _ in 0..<resolvedAlgorithm.byteCount {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw TreeishError.invalidObjectID
            }
            decoded.append(byte)
            index = next
        }
        try self.init(algorithm: resolvedAlgorithm, bytes: decoded)
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
