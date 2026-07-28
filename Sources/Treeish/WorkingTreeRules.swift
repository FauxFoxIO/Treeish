import Foundation
import TreeishFileSystem

struct WorkingTreeRules {
    private struct IgnoreRule {
        let expression: NSRegularExpression
        let negated: Bool
    }

    private struct AttributeRule {
        let expression: NSRegularExpression
        let attributes: [String]
    }

    private struct ResolvedAttributes {
        var textMode: Bool?
        var eol: String?
        var filter: String?
        var workingTreeEncoding: String?
    }

    private let ignores: [IgnoreRule]
    private let attributes: [AttributeRule]

    init(
        worktree: RootDirectory,
        commonDirectory: RootDirectory
    ) throws {
        var parsedIgnores: [IgnoreRule] = []
        if let bytes = try? commonDirectory.read(
            ["info", "exclude"],
            limit: 4 * 1024 * 1024
        ),
           let text = String(bytes: bytes, encoding: .utf8) {
            parsedIgnores += try Self.ignoreRules(text: text, base: "")
        }
        let ruleFiles = try Self.ruleFiles(in: worktree)
        for file in ruleFiles where file.name == ".gitignore" {
            let bytes = try worktree.read(file.components, limit: 4 * 1024 * 1024)
            guard let text = String(bytes: bytes, encoding: .utf8) else { continue }
            parsedIgnores += try Self.ignoreRules(text: text, base: file.base)
        }
        ignores = parsedIgnores
        var parsedAttributes: [AttributeRule] = []
        for file in ruleFiles where file.name == ".gitattributes" {
            let bytes = try worktree.read(file.components, limit: 4 * 1024 * 1024)
            guard let text = String(bytes: bytes, encoding: .utf8) else { continue }
            parsedAttributes += try Self.attributeRules(text: text, base: file.base)
        }
        if let bytes = try? commonDirectory.read(
            ["info", "attributes"],
            limit: 4 * 1024 * 1024
        ),
           let text = String(bytes: bytes, encoding: .utf8) {
            parsedAttributes += try Self.attributeRules(text: text, base: "")
        }
        attributes = parsedAttributes
    }

    private static func ignoreRules(text: String, base: String) throws -> [IgnoreRule] {
        try text.components(separatedBy: .newlines).compactMap { raw in
            var line = raw
            if line.isEmpty { return nil }
            if line.hasPrefix("\\#") { line.removeFirst() }
            else if line.hasPrefix("#") { return nil }
            let negated: Bool
            if line.hasPrefix("\\!") { line.removeFirst(); negated = false }
            else { negated = line.hasPrefix("!"); if negated { line.removeFirst() } }
            guard !line.isEmpty else { return nil }
            return IgnoreRule(
                expression: try expression(
                    pattern: line,
                    directoryRule: line.hasSuffix("/"),
                    base: base
                ),
                negated: negated
            )
        }
    }

    private static func attributeRules(text: String, base: String) throws -> [AttributeRule] {
        var result: [AttributeRule] = []
        for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2 else { continue }
                result.append(
                    AttributeRule(
                        expression: try Self.expression(
                            pattern: String(fields[0]),
                            directoryRule: false,
                            base: base
                        ),
                        attributes: fields.dropFirst().map(String.init)
                    )
                )
        }
        return result
    }

    private static func ruleFiles(
        in worktree: RootDirectory
    ) throws -> [(components: [String], base: String, name: String)] {
        let root = try worktree.url(for: [])
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var result: [(components: [String], base: String, name: String)] = []
        while let item = enumerator.nextObject() {
            guard let url = item as? URL else { continue }
            if url.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
            guard url.lastPathComponent == ".gitignore" || url.lastPathComponent == ".gitattributes" else {
                continue
            }
            let components = try worktree.relativeComponents(for: url)
            let base = components.dropLast().joined(separator: "/")
            result.append((components, base, url.lastPathComponent))
        }
        return result.sorted {
            if $0.components.count != $1.components.count { return $0.components.count < $1.components.count }
            return $0.components.joined(separator: "/") < $1.components.joined(separator: "/")
        }
    }

    func isIgnored(_ path: GitPath) -> Bool {
        let value = path.displayString
        var ignored = false
        for rule in ignores where rule.expression.matches(value) {
            ignored = !rule.negated
        }
        return ignored
    }

    func clean(_ payload: [UInt8], path: GitPath) throws -> [UInt8] {
        let resolved = resolvedAttributes(for: path)
        try validateSupportedConversions(resolved, path: path)
        guard resolved.textMode == true || resolved.eol != nil else {
            return payload
        }
        if resolved.textMode == true, payload.contains(0) {
            return payload
        }
        var normalized: [UInt8] = []
        normalized.reserveCapacity(payload.count)
        var index = 0
        while index < payload.count {
            if payload[index] == 0x0d, index + 1 < payload.count,
               payload[index + 1] == 0x0a {
                normalized.append(0x0a)
                index += 2
            } else {
                normalized.append(payload[index])
                index += 1
            }
        }
        return normalized
    }

    func smudge(_ payload: [UInt8], path: GitPath) throws -> [UInt8] {
        let resolved = resolvedAttributes(for: path)
        try validateSupportedConversions(resolved, path: path)
        guard resolved.textMode != false else {
            return payload
        }
        guard let eol = resolved.eol else {
            return payload
        }
        guard eol == "lf" || eol == "crlf" else {
            throw TreeishError.unsupportedContentConversion(
                path,
                "eol=\(eol)"
            )
        }
        guard eol == "crlf", !payload.contains(0) else {
            return payload
        }
        var converted: [UInt8] = []
        converted.reserveCapacity(payload.count)
        var previous: UInt8?
        for byte in payload {
            if byte == 0x0a, previous != 0x0d {
                converted.append(0x0d)
            }
            converted.append(byte)
            previous = byte
        }
        return converted
    }

    private func validateSupportedConversions(
        _ resolved: ResolvedAttributes,
        path: GitPath
    ) throws {
        if let filter = resolved.filter {
            throw TreeishError.unsupportedContentConversion(
                path,
                "filter=\(filter)"
            )
        }
        if let encoding = resolved.workingTreeEncoding {
            throw TreeishError.unsupportedContentConversion(
                path,
                "working-tree-encoding=\(encoding)"
            )
        }
    }

    private func resolvedAttributes(for path: GitPath) -> ResolvedAttributes {
        let value = path.displayString
        var result = ResolvedAttributes()
        for rule in attributes where rule.expression.matches(value) {
            for attribute in rule.attributes {
                switch attribute {
                case "text", "text=auto":
                    result.textMode = true
                case "-text", "binary":
                    result.textMode = false
                case "!text":
                    result.textMode = nil
                case "-eol", "!eol":
                    result.eol = nil
                case "-filter", "!filter":
                    result.filter = nil
                case "filter":
                    result.filter = "set"
                case "-working-tree-encoding", "!working-tree-encoding":
                    result.workingTreeEncoding = nil
                default:
                    if attribute.hasPrefix("eol=") {
                        result.eol = String(attribute.dropFirst(4))
                    } else if attribute.hasPrefix("filter=") {
                        result.filter = String(attribute.dropFirst(7))
                    } else if attribute.hasPrefix("working-tree-encoding=") {
                        result.workingTreeEncoding = String(
                            attribute.dropFirst(22)
                        )
                    }
                }
            }
        }
        return result
    }

    private static func expression(
        pattern original: String,
        directoryRule: Bool,
        base: String
    ) throws -> NSRegularExpression {
        var pattern = original
        let anchored = pattern.hasPrefix("/")
        if anchored { pattern.removeFirst() }
        if directoryRule, pattern.hasSuffix("/") { pattern.removeLast() }
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
                    continue
                }
                body += "[^/]*"
            } else if character == "?" {
                body += "[^/]"
            } else {
                body += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        let hasSlash = pattern.contains("/")
        let basePrefix = base.isEmpty ? "" : NSRegularExpression.escapedPattern(for: base) + "/"
        let prefix = anchored || hasSlash
            ? "^" + basePrefix
            : "^" + basePrefix + "(?:.*/)?"
        let suffix = directoryRule ? "(?:/.*)?$" : "$"
        return try NSRegularExpression(pattern: prefix + body + suffix)
    }
}

private extension NSRegularExpression {
    func matches(_ string: String) -> Bool {
        firstMatch(
            in: string,
            range: NSRange(string.startIndex..<string.endIndex, in: string)
        ) != nil
    }
}
