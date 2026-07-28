import Foundation
import TreeishCore
import TreeishFileSystem

/// A recoverable before-image for mutations spanning the worktree and index.
///
/// Canonical Git data remains authoritative. The journal exists only while an
/// operation is in flight and opening the repository rolls a prepared journal
/// back before allowing further mutation.
struct WorktreeTransaction {
    private static let path = ["treeish", "worktree-transaction"]

    struct Publication: Codable {
        enum Directory: String, Codable {
            case git
            case common
        }

        enum Kind: String, Codable {
            case file
            case reference
        }

        let directory: Directory
        let path: [String]
        let expected: Data
        let kind: Kind

        init(
            directory: Directory,
            path: [String],
            expected: Data,
            kind: Kind = .file
        ) {
            self.directory = directory
            self.path = path
            self.expected = expected
            self.kind = kind
        }
    }

    private enum State: String, Codable {
        case prepared
        case committed
    }

    private enum EntryKind: String, Codable {
        case missing
        case file
        case symbolicLink
    }

    private struct Entry: Codable {
        let path: String
        let kind: EntryKind
        let payload: Data?
        let permissions: UInt16?
    }

    private struct Journal: Codable {
        let format: Int
        var state: State
        let entries: [Entry]
        let index: Data?
        let publication: Publication?
    }

    private let gitDirectory: RootDirectory
    private let worktree: RootDirectory
    private var journal: Journal

    static func recover(
        gitDirectory: RootDirectory,
        commonDirectory: RootDirectory,
        worktree: RootDirectory,
        maximumBytes: Int
    ) throws {
        guard try gitDirectory.exists(path) else { return }
        let bytes = try gitDirectory.read(path, limit: maximumBytes)
        let journal: Journal
        do {
            journal = try JSONDecoder().decode(Journal.self, from: Data(bytes))
        } catch {
            throw TreeishError.recoveryRequired(
                "Treeish worktree transaction journal is corrupt"
            )
        }
        guard journal.format == 2 else {
            throw TreeishError.recoveryRequired(
                "Treeish worktree transaction journal format is unsupported"
            )
        }
        let wasPublished: Bool
        if let publication = journal.publication {
            wasPublished = isPublished(
                publication,
                gitDirectory: gitDirectory,
                commonDirectory: commonDirectory
            )
        } else {
            wasPublished = false
        }
        if journal.state == .prepared, !wasPublished {
            try restore(
                journal,
                gitDirectory: gitDirectory,
                worktree: worktree
            )
        }
        _ = try gitDirectory.removeAtomically(path)
    }

    static func begin(
        paths: Set<GitPath>,
        gitDirectory: RootDirectory,
        worktree: RootDirectory,
        maximumBytes: Int,
        publication: Publication? = nil
    ) throws -> WorktreeTransaction {
        guard maximumBytes > 0, !(try gitDirectory.exists(path)) else {
            throw TreeishError.recoveryRequired(
                "another Treeish worktree transaction is active"
            )
        }
        var entries: [Entry] = []
        var payloadBytes = 0
        for path in paths.sorted(by: {
            $0.bytes.lexicographicallyPrecedes($1.bytes)
        }) {
            let components = try path.components
            guard try worktree.exists(components) else {
                entries.append(Entry(
                    path: String(decoding: path.bytes, as: UTF8.self),
                    kind: .missing,
                    payload: nil,
                    permissions: nil
                ))
                continue
            }
            let url = try worktree.url(
                for: components,
                followFinalSymlink: false
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let type = attributes[.type] as? FileAttributeType
            let payload: Data
            let kind: EntryKind
            if type == .typeSymbolicLink {
                payload = Data(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: url.path
                    ).utf8
                )
                kind = .symbolicLink
            } else if type == .typeRegular {
                payload = try Data(contentsOf: url)
                kind = .file
            } else {
                throw TreeishError.worktreeCollision(path)
            }
            guard payload.count <= maximumBytes - payloadBytes else {
                throw TreeishError.recoveryRequired(
                    "worktree transaction exceeds its configured byte limit"
                )
            }
            payloadBytes += payload.count
            entries.append(Entry(
                path: String(decoding: path.bytes, as: UTF8.self),
                kind: kind,
                payload: payload,
                permissions: (attributes[.posixPermissions] as? NSNumber)?
                    .uint16Value
            ))
        }
        let index: Data?
        do {
            let bytes = try gitDirectory.read(["index"], limit: maximumBytes)
            guard bytes.count <= maximumBytes - payloadBytes else {
                throw TreeishError.recoveryRequired(
                    "worktree transaction exceeds its configured byte limit"
                )
            }
            index = Data(bytes)
        } catch RootDirectoryError.notFound {
            index = nil
        }
        let journal = Journal(
            format: 2,
            state: .prepared,
            entries: entries,
            index: index,
            publication: publication
        )
        let encoded = try JSONEncoder().encode(journal)
        guard encoded.count <= maximumBytes else {
            throw TreeishError.recoveryRequired(
                "worktree transaction journal exceeds its configured byte limit"
            )
        }
        guard try gitDirectory.compareAndSwap(
            Array(encoded),
            to: Self.path,
            expected: nil,
            requireMissing: true
        ) else {
            throw TreeishError.recoveryRequired(
                "another Treeish worktree transaction is active"
            )
        }
        return WorktreeTransaction(
            gitDirectory: gitDirectory,
            worktree: worktree,
            journal: journal
        )
    }

    static func perform<Value>(
        paths: Set<GitPath>,
        gitDirectory: RootDirectory,
        commonDirectory: RootDirectory,
        worktree: RootDirectory,
        maximumBytes: Int,
        _ body: () throws -> Value
    ) throws -> Value {
        var transaction = try begin(
            paths: paths,
            gitDirectory: gitDirectory,
            worktree: worktree,
            maximumBytes: maximumBytes
        )
        do {
            let value = try body()
            try transaction.commit()
            return value
        } catch {
            try transaction.reconcileAfterFailure(
                commonDirectory: commonDirectory
            )
            throw error
        }
    }

    mutating func commit() throws {
        journal.state = .committed
        let encoded = try JSONEncoder().encode(journal)
        try gitDirectory.writeAtomically(Array(encoded), to: Self.path)
        _ = try gitDirectory.removeAtomically(Self.path)
    }

    mutating func rollback() throws {
        try Self.restore(
            journal,
            gitDirectory: gitDirectory,
            worktree: worktree
        )
        _ = try gitDirectory.removeAtomically(Self.path)
    }

    mutating func reconcileAfterFailure(
        commonDirectory: RootDirectory
    ) throws {
        if let publication = journal.publication {
            if Self.isPublished(
                publication,
                gitDirectory: gitDirectory,
                commonDirectory: commonDirectory
            ) {
                _ = try gitDirectory.removeAtomically(Self.path)
                return
            }
        }
        try rollback()
    }

    private static func isPublished(
        _ publication: Publication,
        gitDirectory: RootDirectory,
        commonDirectory: RootDirectory
    ) -> Bool {
        let directory = publication.directory == .git
            ? gitDirectory
            : commonDirectory
        if publication.kind == .file {
            return (try? directory.read(
                publication.path,
                limit: publication.expected.count + 1
            )) == Array(publication.expected)
        }
        guard let name = try? RefName(
            publication.path.joined(separator: "/")
        ),
              let expectedText = String(
                data: publication.expected,
                encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              let expected = try? ObjectID(hex: expectedText),
              let configuration = try? GitConfiguration.load(
                from: commonDirectory
              ),
              configuration.value(
                section: "extensions",
                key: "refstorage"
              )?.lowercased() == RefStorageFormat.reftable.rawValue
        else { return false }
        let objectFormat = configuration.value(
            section: "extensions",
            key: "objectformat"
        ).flatMap {
            ObjectHashAlgorithm(rawValue: $0.lowercased())
        } ?? .sha1
        guard let value = try? ReftableStack(
            directory: directory,
            objectFormat: objectFormat
        ).reference(name),
              case .direct(let actual, _) = value
        else { return false }
        return actual == expected
    }

    private static func restore(
        _ journal: Journal,
        gitDirectory: RootDirectory,
        worktree: RootDirectory
    ) throws {
        // Remove deepest paths first so a file/directory type change can be
        // restored without retaining children created by the failed operation.
        for entry in journal.entries.sorted(by: {
            $0.path.split(separator: "/").count >
                $1.path.split(separator: "/").count
        }) {
            let path = try GitPath(entry.path)
            let components = try path.components
            if try worktree.exists(components) {
                let url = try worktree.url(
                    for: components,
                    followFinalSymlink: false
                )
                try FileManager.default.removeItem(at: url)
            }
        }
        for entry in journal.entries where entry.kind != .missing {
            let path = try GitPath(entry.path)
            let components = try path.components
            guard let payload = entry.payload else {
                throw TreeishError.recoveryRequired(
                    "Treeish worktree transaction is missing a before-image"
                )
            }
            if entry.kind == .symbolicLink {
                let url = try worktree.url(
                    for: components,
                    followFinalSymlink: false
                )
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    atPath: url.path,
                    withDestinationPath: String(decoding: payload, as: UTF8.self)
                )
            } else {
                try worktree.writeAtomically(
                    Array(payload),
                    to: components
                )
                if let permissions = entry.permissions {
                    let url = try worktree.url(
                        for: components,
                        followFinalSymlink: false
                    )
                    try FileManager.default.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: url.path
                    )
                }
            }
        }
        if let index = journal.index {
            try gitDirectory.writeAtomically(Array(index), to: ["index"])
        } else if try gitDirectory.exists(["index"]) {
            _ = try gitDirectory.removeAtomically(["index"])
        }
    }
}
