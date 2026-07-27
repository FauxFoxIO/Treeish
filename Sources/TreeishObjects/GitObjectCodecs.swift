import Foundation

public struct GitSignature: Sendable, Hashable, Codable {
    public let name: String
    public let email: String
    public let secondsSinceEpoch: Int64
    public let timeZoneOffsetMinutes: Int

    public init(
        name: String,
        email: String,
        secondsSinceEpoch: Int64,
        timeZoneOffsetMinutes: Int
    ) {
        self.name = name
        self.email = email
        self.secondsSinceEpoch = secondsSinceEpoch
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
    }

    public var encoded: String {
        let sign = timeZoneOffsetMinutes < 0 ? "-" : "+"
        let absolute = abs(timeZoneOffsetMinutes)
        let zone = String(format: "%@%02d%02d", sign, absolute / 60, absolute % 60)
        return "\(name) <\(email)> \(secondsSinceEpoch) \(zone)"
    }
}

public enum GitObjectEncoder {
    public static func tag(
        objectHex: String,
        objectType: GitObjectType,
        name: String,
        tagger: GitSignature,
        message: [UInt8]
    ) -> GitObject {
        let header = "object \(objectHex)\ntype \(objectType.rawValue)\ntag \(name)\ntagger \(tagger.encoded)\n\n"
        return GitObject(type: .tag, payload: Array(header.utf8) + message)
    }

    public static func commit(
        treeHex: String,
        parentHexes: [String],
        author: GitSignature,
        committer: GitSignature,
        message: [UInt8]
    ) -> GitObject {
        var header = "tree \(treeHex)\n"
        for parent in parentHexes {
            header += "parent \(parent)\n"
        }
        header += "author \(author.encoded)\n"
        header += "committer \(committer.encoded)\n\n"
        return GitObject(type: .commit, payload: Array(header.utf8) + message)
    }

    public static func tree(entries: [GitTreeEntry]) -> GitObject {
        let sorted = entries.sorted { lhs, rhs in
            treeSortKey(lhs).lexicographicallyPrecedes(treeSortKey(rhs))
        }
        var payload: [UInt8] = []
        for entry in sorted {
            payload.append(contentsOf: entry.mode.rawValue.utf8)
            payload.append(0x20)
            payload.append(contentsOf: entry.name)
            payload.append(0)
            payload.append(contentsOf: entry.objectID)
        }
        return GitObject(type: .tree, payload: payload)
    }

    private static func treeSortKey(_ entry: GitTreeEntry) -> [UInt8] {
        entry.name + (entry.mode == .tree ? [0x2f] : [])
    }
}

public enum GitFileMode: String, Sendable, Codable {
    case regular = "100644"
    case executable = "100755"
    case symbolicLink = "120000"
    case tree = "40000"
    case gitlink = "160000"
}

public struct GitTreeEntry: Sendable, Hashable {
    public let mode: GitFileMode
    public let name: [UInt8]
    public let objectID: [UInt8]

    public init(mode: GitFileMode, name: [UInt8], objectID: [UInt8]) throws {
        guard !name.isEmpty,
              !name.contains(0),
              !name.contains(0x2f),
              objectID.count == 20
        else {
            throw GitObjectError.invalidHeader
        }
        self.mode = mode
        self.name = name
        self.objectID = objectID
    }
}
