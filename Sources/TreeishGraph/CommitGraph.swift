import Foundation
import TreeishCore
import TreeishObjects

public enum CommitGraphError: Error, Sendable, Equatable {
    case objectNotFound
    case expectedCommit
    case malformedCommit
    case traversalLimitExceeded
}

public struct CommitRecord: Sendable, Hashable {
    public let identifier: [UInt8]
    public let tree: [UInt8]
    public let parents: [[UInt8]]
    public let authorTime: Int64?
    public let message: [UInt8]

    public init(identifier: [UInt8], object: GitObject) throws {
        guard identifier.count == 20, object.type == .commit else {
            throw CommitGraphError.expectedCommit
        }
        let separator = Array("\n\n".utf8)
        guard let split = object.payload.firstRange(of: separator) else {
            throw CommitGraphError.malformedCommit
        }
        let headers = object.payload[..<split.lowerBound].split(separator: 0x0a)
        var tree: [UInt8]?
        var parents: [[UInt8]] = []
        var authorTime: Int64?
        for header in headers {
            if header.starts(with: Array("tree ".utf8)) {
                tree = try Self.decodeHex(header.dropFirst(5))
            } else if header.starts(with: Array("parent ".utf8)) {
                parents.append(try Self.decodeHex(header.dropFirst(7)))
            } else if header.starts(with: Array("author ".utf8)),
                      let close = header.lastIndex(of: 0x3e) {
                let suffix = header[header.index(after: close)...]
                    .split(separator: 0x20, omittingEmptySubsequences: true)
                if let value = suffix.first {
                    authorTime = Int64(String(decoding: value, as: UTF8.self))
                }
            }
        }
        guard let tree, tree.count == 20,
              parents.allSatisfy({ $0.count == 20 }) else {
            throw CommitGraphError.malformedCommit
        }
        self.identifier = identifier
        self.tree = tree
        self.parents = parents
        self.authorTime = authorTime
        message = Array(object.payload[split.upperBound...])
    }

    private static func decodeHex(_ bytes: ArraySlice<UInt8>) throws -> [UInt8] {
        guard bytes.count == 40 else { throw CommitGraphError.malformedCommit }
        var output: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let next = bytes.index(index, offsetBy: 2)
            guard let value = UInt8(
                String(decoding: bytes[index..<next], as: UTF8.self),
                radix: 16
            ) else { throw CommitGraphError.malformedCommit }
            output.append(value)
            index = next
        }
        return output
    }
}

public protocol CommitObjectSource: Sendable {
    func object(identifier: [UInt8]) async throws -> GitObject
}

public actor CommitGraph {
    private let source: any CommitObjectSource
    private let maximumVisitedCommits: Int
    private var cache: [[UInt8]: CommitRecord] = [:]

    public init(
        source: any CommitObjectSource,
        maximumVisitedCommits: Int = 1_000_000
    ) {
        self.source = source
        self.maximumVisitedCommits = maximumVisitedCommits
    }

    public func record(_ identifier: [UInt8]) async throws -> CommitRecord {
        if let cached = cache[identifier] { return cached }
        let object = try await source.object(identifier: identifier)
        let value = try CommitRecord(
            identifier: identifier,
            object: object
        )
        cache[identifier] = value
        return value
    }

    public func isAncestor(
        _ ancestor: [UInt8],
        of descendant: [UInt8]
    ) async throws -> Bool {
        if ancestor == descendant { return true }
        var queue = [descendant]
        var visited: Set<[UInt8]> = []
        while let next = queue.popLast() {
            guard visited.count < maximumVisitedCommits else {
                throw CommitGraphError.traversalLimitExceeded
            }
            guard visited.insert(next).inserted else { continue }
            let commit = try await record(next)
            if commit.parents.contains(ancestor) { return true }
            queue.append(contentsOf: commit.parents)
        }
        return false
    }

    public func mergeBases(_ left: [UInt8], _ right: [UInt8]) async throws -> [[UInt8]] {
        let leftDepths = try await ancestorDepths(left)
        let rightDepths = try await ancestorDepths(right)
        let common = Set(leftDepths.keys).intersection(rightDepths.keys)
        let sorted = common.sorted {
            max(leftDepths[$0] ?? .max, rightDepths[$0] ?? .max)
                < max(leftDepths[$1] ?? .max, rightDepths[$1] ?? .max)
        }
        var bases: [[UInt8]] = []
        for candidate in sorted {
            var dominated = false
            for existing in bases where try await isAncestor(candidate, of: existing) {
                dominated = true
                break
            }
            if !dominated { bases.append(candidate) }
        }
        return bases
    }

    public func walk(from starts: [[UInt8]]) async throws -> [CommitRecord] {
        var queue = starts
        var visited: Set<[UInt8]> = []
        var result: [CommitRecord] = []
        while let next = queue.popLast() {
            guard visited.count < maximumVisitedCommits else {
                throw CommitGraphError.traversalLimitExceeded
            }
            guard visited.insert(next).inserted else { continue }
            let commit = try await record(next)
            result.append(commit)
            queue.append(contentsOf: commit.parents)
        }
        return result.sorted {
            ($0.authorTime ?? .min) > ($1.authorTime ?? .min)
        }
    }

    private func ancestorDepths(_ start: [UInt8]) async throws -> [[UInt8]: Int] {
        var depths: [[UInt8]: Int] = [start: 0]
        var queue: [([UInt8], Int)] = [(start, 0)]
        var cursor = 0
        while cursor < queue.count {
            guard depths.count < maximumVisitedCommits else {
                throw CommitGraphError.traversalLimitExceeded
            }
            let (identifier, depth) = queue[cursor]
            cursor += 1
            for parent in try await record(identifier).parents {
                let nextDepth = depth + 1
                if nextDepth < depths[parent, default: .max] {
                    depths[parent] = nextDepth
                    queue.append((parent, nextDepth))
                }
            }
        }
        return depths
    }
}

private extension Array where Element: Equatable {
    func firstRange(of needle: [Element]) -> Range<Int>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        for index in 0...(count - needle.count)
        where self[index..<(index + needle.count)].elementsEqual(needle) {
            return index..<(index + needle.count)
        }
        return nil
    }
}
