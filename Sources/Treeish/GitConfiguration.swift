import Foundation
import TreeishCore
import TreeishFileSystem

enum GitConfigurationError: Error, Sendable, Equatable {
    case invalidSyntax(line: Int)
    case includeCycle
    case includeDepthExceeded
    case resourceLimitExceeded
    case includeOutsideRoot
}

struct GitConfiguration: Sendable {
    struct Entry: Sendable, Equatable {
        let section: String
        let subsection: String?
        let key: String
        let value: String
        let line: Int
    }

    let bytes: [UInt8]
    let entries: [Entry]

    init(bytes: [UInt8], maximumBytes: Int = 16 * 1024 * 1024) throws {
        guard bytes.count <= maximumBytes else {
            throw GitConfigurationError.resourceLimitExceeded
        }
        self.bytes = bytes
        entries = try Self.parse(bytes)
    }

    static func load(
        from directory: RootDirectory,
        path: [String] = ["config"],
        maximumBytes: Int = 16 * 1024 * 1024,
        maximumDepth: Int = 8
    ) throws -> GitConfiguration {
        var visited: Set<String> = []
        var total = 0
        let loaded = try loadEntries(
            from: directory,
            path: path,
            maximumBytes: maximumBytes,
            maximumDepth: maximumDepth,
            depth: 0,
            visited: &visited,
            total: &total
        )
        let rootBytes = try directory.read(path, limit: maximumBytes)
        return GitConfiguration(bytes: rootBytes, entries: loaded)
    }

    func integer(section: String, key: String) -> Int? {
        value(section: section, key: key).flatMap(Int.init)
    }

    func value(section: String, subsection: String? = nil, key: String) -> String? {
        entries.last {
            $0.section.caseInsensitiveCompare(section) == .orderedSame &&
            $0.subsection == subsection &&
            $0.key.caseInsensitiveCompare(key) == .orderedSame
        }?.value
    }

    func values(in section: String) -> [(String, String)] {
        entries.filter { $0.section.caseInsensitiveCompare(section) == .orderedSame }
            .map { ($0.key, $0.value) }
    }

    func replacing(section: String, subsection: String? = nil, key: String, value: String) throws -> [UInt8] {
        guard !value.contains("\n"), !value.contains("\0") else {
            throw GitConfigurationError.invalidSyntax(line: 0)
        }
        var lines = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let entry = entries.last(where: {
            $0.section.caseInsensitiveCompare(section) == .orderedSame &&
            $0.subsection == subsection &&
            $0.key.caseInsensitiveCompare(key) == .orderedSame
        }), lines.indices.contains(entry.line - 1) {
            let indentation = String(lines[entry.line - 1].prefix { $0 == " " || $0 == "\t" })
            lines[entry.line - 1] = "\(indentation)\(key) = \(Self.quote(value))"
        } else {
            if lines.last != "" { lines.append("") }
            let header = subsection.map { "[\(section) \"\(Self.escape($0))\"]" } ?? "[\(section)]"
            lines.append(header)
            lines.append("\t\(key) = \(Self.quote(value))")
            lines.append("")
        }
        return Array(lines.joined(separator: "\n").utf8)
    }

    private init(bytes: [UInt8], entries: [Entry]) {
        self.bytes = bytes
        self.entries = entries
    }

    private static func loadEntries(
        from directory: RootDirectory,
        path: [String],
        maximumBytes: Int,
        maximumDepth: Int,
        depth: Int,
        visited: inout Set<String>,
        total: inout Int
    ) throws -> [Entry] {
        guard depth <= maximumDepth else { throw GitConfigurationError.includeDepthExceeded }
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GitConfigurationError.includeOutsideRoot
        }
        let identity = path.joined(separator: "/")
        guard visited.insert(identity).inserted else { throw GitConfigurationError.includeCycle }
        defer { visited.remove(identity) }
        let remaining = maximumBytes - total
        guard remaining >= 0 else { throw GitConfigurationError.resourceLimitExceeded }
        let data = try directory.read(path, limit: remaining)
        total += data.count
        let document = try GitConfiguration(bytes: data, maximumBytes: remaining)
        var result: [Entry] = []
        let parent = Array(path.dropLast())
        for entry in document.entries {
            result.append(entry)
            guard entry.section == "include", entry.key == "path" else { continue }
            let includePath = entry.value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !entry.value.hasPrefix("/"), !entry.value.hasPrefix("~/") else {
                throw GitConfigurationError.includeOutsideRoot
            }
            result += try loadEntries(
                from: directory,
                path: parent + includePath,
                maximumBytes: maximumBytes,
                maximumDepth: maximumDepth,
                depth: depth + 1,
                visited: &visited,
                total: &total
            )
        }
        return result
    }

    private static func parse(_ bytes: [UInt8]) throws -> [Entry] {
        guard let source = String(bytes: bytes, encoding: .utf8) else {
            throw GitConfigurationError.invalidSyntax(line: 1)
        }
        let physical = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var logical: [(String, Int)] = []
        var pending = ""
        var pendingLine = 1
        for (offset, raw) in physical.enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if pending.isEmpty { pendingLine = offset + 1 }
            if line.hasSuffix("\\") && !line.hasSuffix("\\\\") {
                pending += line.dropLast()
            } else {
                logical.append((pending + line, pendingLine))
                pending = ""
            }
        }
        if !pending.isEmpty { throw GitConfigurationError.invalidSyntax(line: pendingLine) }
        var section = ""
        var subsection: String?
        var output: [Entry] = []
        for (raw, lineNumber) in logical {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw GitConfigurationError.invalidSyntax(line: lineNumber) }
                let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if let quote = header.firstIndex(of: "\"") {
                    section = header[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
                    let suffix = header[quote...]
                    guard suffix.last == "\"" else { throw GitConfigurationError.invalidSyntax(line: lineNumber) }
                    subsection = try unescape(String(suffix.dropFirst().dropLast()), line: lineNumber)
                } else if let dot = header.firstIndex(of: ".") {
                    section = String(header[..<dot]).lowercased()
                    subsection = String(header[header.index(after: dot)...])
                } else {
                    section = header.lowercased()
                    subsection = nil
                }
                guard !section.isEmpty else { throw GitConfigurationError.invalidSyntax(line: lineNumber) }
                continue
            }
            guard !section.isEmpty else { throw GitConfigurationError.invalidSyntax(line: lineNumber) }
            let equals = line.firstIndex(of: "=")
            let rawKey = equals.map { String(line[..<$0]) } ?? line
            let key = rawKey.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw GitConfigurationError.invalidSyntax(line: lineNumber)
            }
            let rawValue = equals.map { String(line[line.index(after: $0)...]) } ?? "true"
            let value = try parseValue(rawValue, line: lineNumber)
            output.append(Entry(section: section, subsection: subsection, key: key, value: value, line: lineNumber))
        }
        return output
    }

    private static func parseValue(_ raw: String, line: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            guard value.hasSuffix("\"") else { throw GitConfigurationError.invalidSyntax(line: line) }
            return try unescape(String(value.dropFirst().dropLast()), line: line)
        }
        var output = ""
        var escaped = false
        for character in value {
            if escaped { output.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "#" || character == ";" { break }
            output.append(character)
        }
        if escaped { throw GitConfigurationError.invalidSyntax(line: line) }
        return output.trimmingCharacters(in: .whitespaces)
    }

    private static func unescape(_ value: String, line: Int) throws -> String {
        var output = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "b": output.append("\u{8}")
                case "\\", "\"": output.append(character)
                default: throw GitConfigurationError.invalidSyntax(line: line)
                }
                escaped = false
            } else if character == "\\" { escaped = true }
            else { output.append(character) }
        }
        guard !escaped else { throw GitConfigurationError.invalidSyntax(line: line) }
        return output
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func quote(_ value: String) -> String {
        "\"\(escape(value).replacingOccurrences(of: "\n", with: "\\n"))\""
    }
}
