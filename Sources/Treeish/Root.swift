import Foundation
import TreeishFileSystem

public struct TreeishRootIdentity: Sendable, Hashable, Codable {
    public let canonicalPath: String

    public init(canonicalPath: String) {
        self.canonicalPath = canonicalPath
    }
}
public struct TreeishRootPolicy: Sendable, Hashable, Codable {
    public var allowsSiblingWorktrees: Bool
    public var allowsExternalAlternates: Bool
    public var readOnly: Bool

    public init(
        allowsSiblingWorktrees: Bool = true,
        allowsExternalAlternates: Bool = false,
        readOnly: Bool = false
    ) {
        self.allowsSiblingWorktrees = allowsSiblingWorktrees
        self.allowsExternalAlternates = allowsExternalAlternates
        self.readOnly = readOnly
    }

    public static let repositoryAndWorktrees = TreeishRootPolicy()
}

public struct TreeishRoot: Sendable {
    public let identity: TreeishRootIdentity
    public let policy: TreeishRootPolicy
    internal let directory: RootDirectory

    public static func localDirectory(
        at url: URL,
        policy: TreeishRootPolicy = .repositoryAndWorktrees
    ) async throws -> TreeishRoot {
        let directory = try RootDirectory(url: url)
        return TreeishRoot(
            identity: TreeishRootIdentity(
                canonicalPath: directory.identity.canonicalPath
            ),
            policy: policy,
            directory: directory
        )
    }

    internal init(
        identity: TreeishRootIdentity,
        policy: TreeishRootPolicy,
        directory: RootDirectory
    ) {
        self.identity = identity
        self.policy = policy
        self.directory = directory
    }
}
