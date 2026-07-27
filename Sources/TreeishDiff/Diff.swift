import Foundation
import TreeishCore

public enum DiffLine: Sendable, Hashable {
    case context([UInt8])
    case deletion([UInt8])
    case insertion([UInt8])
}

public enum ContentDiff: Sendable, Hashable {
    case identical
    case binary(oldBytes: Int, newBytes: Int)
    case text([DiffLine])
}

public enum DiffError: Error, Sendable, Equatable {
    case resourceLimitExceeded
    case malformedPatch(Int)
    case pathMismatch
    case contextMismatch
    case ambiguousContext
}

public struct UnifiedPatchLimits: Sendable, Hashable, Codable {
    public var maximumBytes: Int
    public var maximumFiles: Int
    public var maximumHunksPerFile: Int
    public var maximumLinesPerHunk: Int
    public var maximumOffsetSearch: Int

    public init(
        maximumBytes: Int = 64 * 1024 * 1024,
        maximumFiles: Int = 10_000,
        maximumHunksPerFile: Int = 100_000,
        maximumLinesPerHunk: Int = 1_000_000,
        maximumOffsetSearch: Int = 1_000
    ) {
        self.maximumBytes = maximumBytes
        self.maximumFiles = maximumFiles
        self.maximumHunksPerFile = maximumHunksPerFile
        self.maximumLinesPerHunk = maximumLinesPerHunk
        self.maximumOffsetSearch = maximumOffsetSearch
    }
}

public struct UnifiedPatch: Sendable, Hashable {
    public let files: [UnifiedFilePatch]

    public init(
        bytes: [UInt8],
        limits: UnifiedPatchLimits = .init()
    ) throws {
        self.files = try UnifiedPatchParser.parse(bytes, limits: limits)
    }
}

public struct UnifiedFilePatch: Sendable, Hashable {
    public let oldPath: [UInt8]?
    public let newPath: [UInt8]?
    public let hunks: [UnifiedHunk]

    public func apply(
        to original: [UInt8],
        maximumOffsetSearch: Int = 1_000
    ) throws -> [UInt8] {
        var lines = UnifiedPatchParser.lines(original)
        var accumulatedOffset = 0
        for hunk in hunks {
            let removed = hunk.lines.compactMap { line -> [UInt8]? in
                switch line {
                case .context(let value), .deletion(let value): value
                case .insertion: nil
                }
            }
            let added = hunk.lines.compactMap { line -> [UInt8]? in
                switch line {
                case .context(let value), .insertion(let value): value
                case .deletion: nil
                }
            }
            let expected = max(0, hunk.oldStart - 1 + accumulatedOffset)
            let lower = max(0, expected - maximumOffsetSearch)
            let upper = min(lines.count, expected + maximumOffsetSearch)
            guard lower <= upper, removed.count <= lines.count else {
                throw DiffError.contextMismatch
            }
            let matches = (lower...upper).filter { candidate in
                candidate <= lines.count - removed.count
                    && Array(lines[candidate..<(candidate + removed.count)]) == removed
            }
            guard matches.count <= 1 else { throw DiffError.ambiguousContext }
            guard let location = matches.first else { throw DiffError.contextMismatch }
            lines.replaceSubrange(location..<(location + removed.count), with: added)
            accumulatedOffset += added.count - removed.count
        }
        return lines.flatMap { $0 }
    }
}

public struct UnifiedHunk: Sendable, Hashable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [UnifiedPatchLine]
}

public enum UnifiedPatchLine: Sendable, Hashable {
    case context([UInt8])
    case deletion([UInt8])
    case insertion([UInt8])
}

private enum UnifiedPatchParser {
    static func parse(
        _ bytes: [UInt8],
        limits: UnifiedPatchLimits
    ) throws -> [UnifiedFilePatch] {
        guard bytes.count <= limits.maximumBytes else {
            throw DiffError.resourceLimitExceeded
        }
        let sourceLines = lines(bytes).map { line -> [UInt8] in
            line.last == 0x0a ? line : line + [0x0a]
        }
        var files: [UnifiedFilePatch] = []
        var index = 0
        while index < sourceLines.count {
            if sourceLines[index].starts(with: Array("diff --git ".utf8)) {
                index += 1
                while index < sourceLines.count,
                      !sourceLines[index].starts(with: Array("--- ".utf8)) {
                    guard !sourceLines[index].starts(with: Array("GIT binary patch".utf8)),
                          !sourceLines[index].starts(with: Array("Binary files ".utf8)) else {
                        throw DiffError.malformedPatch(index + 1)
                    }
                    index += 1
                }
            }
            guard index < sourceLines.count else { break }
            guard sourceLines[index].starts(with: Array("--- ".utf8)) else {
                if sourceLines[index].allSatisfy({ $0 == 0x0a || $0 == 0x0d }) {
                    index += 1
                    continue
                }
                throw DiffError.malformedPatch(index + 1)
            }
            let oldPath = try path(sourceLines[index], prefix: "--- ", line: index + 1)
            index += 1
            guard index < sourceLines.count,
                  sourceLines[index].starts(with: Array("+++ ".utf8)) else {
                throw DiffError.malformedPatch(index + 1)
            }
            let newPath = try path(sourceLines[index], prefix: "+++ ", line: index + 1)
            index += 1
            var hunks: [UnifiedHunk] = []
            while index < sourceLines.count,
                  sourceLines[index].starts(with: Array("@@ ".utf8)) {
                guard hunks.count < limits.maximumHunksPerFile else {
                    throw DiffError.resourceLimitExceeded
                }
                let header = String(
                    decoding: sourceLines[index], as: UTF8.self
                ).split(separator: " ").map(String.init)
                guard header.count >= 4,
                      let oldRange = range(header[1], sign: "-"),
                      let newRange = range(header[2], sign: "+") else {
                    throw DiffError.malformedPatch(index + 1)
                }
                index += 1
                var patchLines: [UnifiedPatchLine] = []
                var oldCount = 0
                var newCount = 0
                while index < sourceLines.count {
                    let line = sourceLines[index]
                    guard let prefix = line.first else {
                        throw DiffError.malformedPatch(index + 1)
                    }
                    if prefix == 0x40 || line.starts(with: Array("--- ".utf8))
                        || line.starts(with: Array("diff --git ".utf8)) {
                        break
                    }
                    if prefix == 0x5c {
                        guard line.starts(with: Array("\\ No newline at end of file".utf8)),
                              !patchLines.isEmpty else {
                            throw DiffError.malformedPatch(index + 1)
                        }
                        patchLines[patchLines.count - 1] = withoutTrailingNewline(
                            patchLines[patchLines.count - 1]
                        )
                        index += 1
                        continue
                    }
                    let content = Array(line.dropFirst())
                    switch prefix {
                    case 0x20:
                        patchLines.append(.context(content)); oldCount += 1; newCount += 1
                    case 0x2d:
                        patchLines.append(.deletion(content)); oldCount += 1
                    case 0x2b:
                        patchLines.append(.insertion(content)); newCount += 1
                    default:
                        throw DiffError.malformedPatch(index + 1)
                    }
                    guard patchLines.count <= limits.maximumLinesPerHunk else {
                        throw DiffError.resourceLimitExceeded
                    }
                    index += 1
                }
                guard oldCount == oldRange.count, newCount == newRange.count else {
                    throw DiffError.malformedPatch(index + 1)
                }
                hunks.append(
                    UnifiedHunk(
                        oldStart: oldRange.start,
                        oldCount: oldRange.count,
                        newStart: newRange.start,
                        newCount: newRange.count,
                        lines: patchLines
                    )
                )
            }
            guard !hunks.isEmpty, oldPath != nil || newPath != nil else {
                throw DiffError.malformedPatch(index + 1)
            }
            if let oldPath, let newPath, oldPath != newPath {
                throw DiffError.pathMismatch
            }
            files.append(
                UnifiedFilePatch(oldPath: oldPath, newPath: newPath, hunks: hunks)
            )
            guard files.count <= limits.maximumFiles else {
                throw DiffError.resourceLimitExceeded
            }
        }
        return files
    }

    static func lines(_ bytes: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in bytes {
            current.append(byte)
            if byte == 0x0a { result.append(current); current = [] }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func path(
        _ lineBytes: [UInt8],
        prefix: String,
        line: Int
    ) throws -> [UInt8]? {
        var value = Array(lineBytes.dropFirst(prefix.utf8.count))
        while value.last == 0x0a || value.last == 0x0d { value.removeLast() }
        if let tab = value.firstIndex(of: 0x09) { value = Array(value[..<tab]) }
        if value == Array("/dev/null".utf8) { return nil }
        if value.starts(with: Array("a/".utf8)) || value.starts(with: Array("b/".utf8)) {
            value.removeFirst(2)
        }
        guard !value.isEmpty, !value.contains(0), value.first != 0x2f,
              !value.split(separator: 0x2f).contains(where: {
                  $0 == [0x2e] || $0 == [0x2e, 0x2e] || $0.isEmpty
              }) else {
            throw DiffError.malformedPatch(line)
        }
        return value
    }

    private static func range(
        _ value: String,
        sign: Character
    ) -> (start: Int, count: Int)? {
        guard value.first == sign else { return nil }
        let pieces = value.dropFirst().split(separator: ",", maxSplits: 1)
        guard let start = Int(pieces[0]), start >= 0 else { return nil }
        let count = pieces.count == 2 ? Int(pieces[1]) : 1
        guard let count, count >= 0 else { return nil }
        return (start, count)
    }

    private static func withoutTrailingNewline(
        _ line: UnifiedPatchLine
    ) -> UnifiedPatchLine {
        func trim(_ value: [UInt8]) -> [UInt8] {
            value.last == 0x0a ? Array(value.dropLast()) : value
        }
        switch line {
        case .context(let value): return .context(trim(value))
        case .deletion(let value): return .deletion(trim(value))
        case .insertion(let value): return .insertion(trim(value))
        }
    }
}

public enum DiffEngine {
    public static func diff(
        old: [UInt8],
        new: [UInt8],
        maximumMatrixCells: Int = 4_000_000
    ) throws -> ContentDiff {
        if old == new { return .identical }
        if old.contains(0) || new.contains(0) {
            return .binary(oldBytes: old.count, newBytes: new.count)
        }
        let left = lines(old)
        let right = lines(new)
        guard left.count == 0 || right.count <= maximumMatrixCells / max(1, left.count) else {
            throw DiffError.resourceLimitExceeded
        }
        var matrix = Array(
            repeating: Array(repeating: 0, count: right.count + 1),
            count: left.count + 1
        )
        if !left.isEmpty, !right.isEmpty {
            for i in stride(from: left.count - 1, through: 0, by: -1) {
                for j in stride(from: right.count - 1, through: 0, by: -1) {
                    matrix[i][j] = left[i] == right[j]
                        ? matrix[i + 1][j + 1] + 1
                        : max(matrix[i + 1][j], matrix[i][j + 1])
                }
            }
        }
        var edits: [DiffLine] = []
        var i = 0
        var j = 0
        while i < left.count || j < right.count {
            if i < left.count, j < right.count, left[i] == right[j] {
                edits.append(.context(left[i])); i += 1; j += 1
            } else if j < right.count,
                      i == left.count || matrix[i][j + 1] >= matrix[i + 1][j] {
                edits.append(.insertion(right[j])); j += 1
            } else {
                edits.append(.deletion(left[i])); i += 1
            }
        }
        return .text(edits)
    }

    private static func lines(_ bytes: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in bytes {
            current.append(byte)
            if byte == 0x0a { result.append(current); current = [] }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
