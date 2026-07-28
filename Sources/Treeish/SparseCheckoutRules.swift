import Foundation
import TreeishFileSystem

struct SparseCheckoutRules {
    private struct Rule {
        let expression: NSRegularExpression
        let included: Bool
    }

    private let rules: [Rule]
    private let isEnabled: Bool

    init(
        gitDirectory: RootDirectory,
        commonDirectory: RootDirectory
    ) throws {
        let configuration = try GitConfiguration.load(from: commonDirectory)
        var enabled = Self.boolean(
            configuration.value(
                section: "core",
                key: "sparsecheckout"
            )
        )
        if Self.boolean(
            configuration.value(
                section: "extensions",
                key: "worktreeconfig"
            )
        ), try gitDirectory.exists(["config.worktree"]) {
            let worktreeConfiguration = try GitConfiguration.load(
                from: gitDirectory,
                path: ["config.worktree"]
            )
            if let value = worktreeConfiguration.value(
                section: "core",
                key: "sparsecheckout"
            ) {
                enabled = Self.boolean(value)
            }
        }
        isEnabled = enabled
        guard enabled else {
            rules = []
            return
        }
        let bytes = try gitDirectory.read(
            ["info", "sparse-checkout"],
            limit: 16 * 1024 * 1024
        )
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw TreeishError.pathEncodingUnsupported
        }
        var parsed: [Rule] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("\\#") {
                line.removeFirst()
            } else if line.hasPrefix("#") {
                continue
            }
            let included: Bool
            if line.hasPrefix("\\!") {
                line.removeFirst()
                included = true
            } else if line.hasPrefix("!") {
                line.removeFirst()
                included = false
            } else {
                included = true
            }
            guard !line.isEmpty else {
                continue
            }
            let directory = line.hasSuffix("/")
            parsed.append(
                Rule(
                    expression: try Self.expression(
                        pattern: line,
                        directoryRule: directory
                    ),
                    included: included
                )
            )
        }
        rules = parsed
    }

    var enabled: Bool {
        isEnabled
    }

    func includes(_ path: GitPath) -> Bool {
        guard isEnabled else {
            return true
        }
        let value = path.displayString
        var included = false
        for rule in rules where rule.expression.matches(value) {
            included = rule.included
        }
        return included
    }

    private static func boolean(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else {
            return false
        }
        return ["true", "yes", "on", "1"].contains(value)
    }

    private static func expression(
        pattern original: String,
        directoryRule: Bool
    ) throws -> NSRegularExpression {
        var pattern = original
        let anchored = pattern.hasPrefix("/")
        if anchored {
            pattern.removeFirst()
        }
        if directoryRule, pattern.hasSuffix("/") {
            pattern.removeLast()
        }
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
                body += NSRegularExpression.escapedPattern(
                    for: String(character)
                )
            }
            index = pattern.index(after: index)
        }
        let prefix = anchored || pattern.contains("/")
            ? "^"
            : "^(?:.*/)?"
        let suffix = directoryRule ? "/.*$" : "$"
        return try NSRegularExpression(
            pattern: prefix + body + suffix
        )
    }
}

private extension NSRegularExpression {
    func matches(_ string: String) -> Bool {
        firstMatch(
            in: string,
            range: NSRange(
                string.startIndex..<string.endIndex,
                in: string
            )
        ) != nil
    }
}
