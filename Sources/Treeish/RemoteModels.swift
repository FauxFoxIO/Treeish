import Foundation
import TreeishHTTP

public enum GitRemoteTransport: String, Sendable, Hashable, Codable {
    case https
    case ssh
}

/// A validated HTTPS or SSH Git remote.
///
/// SSH remotes accept both `ssh://` URLs and SCP-style values such as
/// `git@example.com:owner/repository.git`. Credentials must be supplied through
/// ``RepositoryServices`` and are never accepted in the URL.
public struct RemoteURL: Sendable, Hashable, Codable, CustomStringConvertible {
    public let url: URL
    public let transport: GitRemoteTransport

    public init(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              let transport = GitRemoteTransport(rawValue: scheme),
              url.host != nil,
              url.password == nil,
              transport == .ssh || url.user == nil,
              transport == .https || !url.path.isEmpty
        else {
            throw TreeishError.invalidPath
        }
        self.url = url
        self.transport = transport
    }

    public init(_ value: String) throws {
        if value.contains("://") {
            guard let url = URL(string: value) else {
                throw TreeishError.invalidPath
            }
            try self.init(url)
            return
        }

        guard !value.contains("\0"),
              !value.contains("\n"),
              let separator = value.firstIndex(of: ":"),
              separator != value.startIndex
        else {
            throw TreeishError.invalidPath
        }
        let authority = String(value[..<separator])
        let path = String(value[value.index(after: separator)...])
        guard !path.isEmpty, !authority.contains("[") else {
            throw TreeishError.invalidPath
        }
        let pieces = authority.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let username = pieces.count == 2 ? String(pieces[0]) : "git"
        let host = String(pieces.last ?? "")
        guard !username.isEmpty, !host.isEmpty else {
            throw TreeishError.invalidPath
        }
        var components = URLComponents()
        components.scheme = "ssh"
        components.user = username
        components.host = host
        components.path = "/" + path
        guard let url = components.url else {
            throw TreeishError.invalidPath
        }
        try self.init(url)
    }

    public var description: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-remote>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<remote>"
    }

    public var sshEndpoint: SSHRemoteEndpoint? {
        guard transport == .ssh, let host = url.host else {
            return nil
        }
        return SSHRemoteEndpoint(
            host: host,
            port: url.port ?? 22,
            username: url.user ?? "git",
            repositoryPath: String(url.path.drop(while: { $0 == "/" }))
        )
    }
}

public struct GitAuthenticationChallenge: Sendable, Hashable {
    public let scheme: String
    public let host: String
    public let port: Int?
    public let path: String

    public init(scheme: String, host: String, port: Int?, path: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }
}

public struct GitCredential: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    private let header: String

    public static func bearer(_ token: String) -> GitCredential {
        GitCredential(header: "Bearer \(token)")
    }

    public static func basic(username: String, password: String) -> GitCredential {
        let value = Data("\(username):\(password)".utf8).base64EncodedString()
        return GitCredential(header: "Basic \(value)")
    }

    /// Creates the HTTP Basic credential expected by GitHub for token-based Git access.
    public static func githubToken(_ token: String) -> GitCredential {
        basic(username: "x-access-token", password: token)
    }

    private init(header: String) { self.header = header }
    internal var authorizationHeader: String { header }
    public var description: String { "<redacted-git-credential>" }
    public var debugDescription: String { description }
}

public enum GitCredentialDisposition: Sendable {
    case use(GitCredential)
    case reject
    case cancel
}

public protocol GitCredentialProvider: Sendable {
    func credential(for challenge: GitAuthenticationChallenge) async throws -> GitCredentialDisposition
}

/// The connection details derived from an SSH remote.
///
/// `repositoryPath` is passed to the selected Git service as an opaque path. An
/// SSH transport must not interpret it as a local filesystem path.
public struct SSHRemoteEndpoint: Sendable, Hashable, Codable {
    public let host: String
    public let port: Int
    public let username: String
    public let repositoryPath: String

    public init(
        host: String,
        port: Int = 22,
        username: String = "git",
        repositoryPath: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.repositoryPath = repositoryPath
    }
}

public enum SSHGitService: String, Sendable, Hashable, Codable {
    case uploadPack = "git-upload-pack"
    case receivePack = "git-receive-pack"
}

/// A request to open one Git service over an authenticated SSH connection.
public struct SSHGitSessionRequest: Sendable, Hashable, Codable {
    public let endpoint: SSHRemoteEndpoint
    public let service: SSHGitService

    public init(endpoint: SSHRemoteEndpoint, service: SSHGitService) {
        self.endpoint = endpoint
        self.service = service
    }
}

/// A stateful Git service session carried over SSH.
///
/// The advertisement and request exchange occur on the same remote process.
public protocol SSHGitSession: Sendable {
    func advertisement() async throws -> [UInt8]
    func exchange(_ request: [UInt8]) async throws -> [UInt8]
}

/// Opens authenticated and host-verified SSH sessions for Treeish.
///
/// Implementations own encryption, authentication, key storage, host-key
/// verification, and execution of the requested Git service. Treeish owns the
/// pkt-line and pack protocol exchanged through the returned session.
public protocol SSHGitTransport: Sendable {
    func open(_ request: SSHGitSessionRequest) async throws -> any SSHGitSession
}

public struct RepositoryServices: Sendable {
    public var credentials: (any GitCredentialProvider)?
    public var httpTransport: (any SmartHTTPTransport)?
    public var sshTransport: (any SSHGitTransport)?

    public init(
        credentials: (any GitCredentialProvider)? = nil,
        httpTransport: (any SmartHTTPTransport)? = nil,
        sshTransport: (any SSHGitTransport)? = nil
    ) {
        self.credentials = credentials
        self.httpTransport = httpTransport
        self.sshTransport = sshTransport
    }
}

/// A canonical Git packfile filter specification.
public struct GitObjectFilter: Sendable, Hashable, Codable,
    CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 4_096,
              rawValue.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
        else {
            throw TreeishError.invalidPath
        }
        self.rawValue = rawValue
    }

    private init(validated rawValue: String) {
        self.rawValue = rawValue
    }

    public static let blobNone = GitObjectFilter(validated: "blob:none")

    public static func blobLimit(_ bytes: UInt64) -> GitObjectFilter {
        GitObjectFilter(validated: "blob:limit=\(bytes)")
    }

    public static func treeDepth(_ depth: UInt64) -> GitObjectFilter {
        GitObjectFilter(validated: "tree:\(depth)")
    }

    public var description: String { rawValue }
}

public struct FetchRequest: Sendable, Hashable {
    public let remote: RemoteURL
    public let remoteName: String
    public let refNames: [RefName]
    public let filter: GitObjectFilter?
    public let depth: UInt32?

    public init(
        remote: RemoteURL,
        remoteName: String = "origin",
        refNames: [RefName] = [],
        filter: GitObjectFilter? = nil,
        depth: UInt32? = nil
    ) throws {
        guard !remoteName.isEmpty,
              remoteName.allSatisfy({
                  $0.isLetter || $0.isNumber || "-_.".contains($0)
              }),
              depth.map({ $0 > 0 }) ?? true
        else { throw TreeishError.invalidRefName }
        self.remote = remote
        self.remoteName = remoteName
        self.refNames = refNames
        self.filter = filter
        self.depth = depth
    }
}

public struct FetchResult: Sendable, Hashable, Codable {
    public let receivedObjects: Int
    public let updatedReferences: [RefUpdateResult]
    public let remoteHead: RefName?
    public let shallowBoundaries: [ObjectID]

    public init(
        receivedObjects: Int,
        updatedReferences: [RefUpdateResult],
        remoteHead: RefName?,
        shallowBoundaries: [ObjectID] = []
    ) {
        self.receivedObjects = receivedObjects
        self.updatedReferences = updatedReferences
        self.remoteHead = remoteHead
        self.shallowBoundaries = shallowBoundaries
    }
}

public struct CloneRequest: Sendable, Hashable {
    public let remote: RemoteURL
    public let destination: GitPath
    public let branch: RefName?
    public let remoteName: String
    public let filter: GitObjectFilter?
    public let depth: UInt32?

    public init(
        remote: RemoteURL,
        destination: GitPath,
        branch: RefName? = nil,
        remoteName: String = "origin",
        filter: GitObjectFilter? = nil,
        depth: UInt32? = nil
    ) throws {
        guard branch == nil || branch?.description.hasPrefix("refs/heads/") == true,
              !remoteName.isEmpty,
              remoteName.allSatisfy({ $0.isLetter || $0.isNumber || "-_ .".contains($0) }),
              !remoteName.contains(" "),
              depth.map({ $0 > 0 }) ?? true
        else { throw TreeishError.invalidRefName }
        self.remote = remote
        self.destination = destination
        self.branch = branch
        self.remoteName = remoteName
        self.filter = filter
        self.depth = depth
    }
}

public struct PushRefspec: Sendable, Hashable, Codable {
    public let source: RefName?
    public let destination: RefName
    public let force: Bool

    public init(
        source: RefName?,
        destination: RefName,
        force: Bool = false
    ) {
        self.source = source
        self.destination = destination
        self.force = force
    }
}

public struct PushRequest: Sendable, Hashable {
    public let remote: RemoteURL
    public let refspecs: [PushRefspec]
    public let requiresAtomic: Bool
    public let options: [String]

    public init(
        remote: RemoteURL,
        refspecs: [PushRefspec],
        requiresAtomic: Bool = false,
        options: [String] = []
    ) throws {
        guard !refspecs.isEmpty,
              options.count <= 1_024,
              options.allSatisfy({
                  !$0.isEmpty
                      && $0.utf8.count <= 65_516
                      && !$0.contains("\0")
                      && !$0.contains("\n")
              }) else {
            throw TreeishError.invalidRefName
        }
        self.remote = remote
        self.refspecs = refspecs
        self.requiresAtomic = requiresAtomic
        self.options = options
    }

    public init(
        remote: RemoteURL,
        source: RefName,
        destination: RefName? = nil,
        force: Bool = false
    ) {
        self.remote = remote
        refspecs = [PushRefspec(
            source: source,
            destination: destination ?? source,
            force: force
        )]
        requiresAtomic = false
        options = []
    }
}

public enum PushRefDisposition: Sendable, Hashable, Codable {
    case accepted
    case rejected(reason: String)
}

public struct PushRefResult: Sendable, Hashable, Codable {
    public let reference: RefName
    public let previous: ObjectID?
    public let current: ObjectID?
    public let disposition: PushRefDisposition

    public init(
        reference: RefName,
        previous: ObjectID?,
        current: ObjectID?,
        disposition: PushRefDisposition
    ) {
        self.reference = reference
        self.previous = previous
        self.current = current
        self.disposition = disposition
    }
}

public struct PushReconciliation: Sendable, Hashable, Codable {
    public let expectedReferences: [RefName: ObjectID?]

    public init(expectedReferences: [RefName: ObjectID?]) {
        self.expectedReferences = expectedReferences
    }
}

public struct PushResult: Sendable, Hashable, Codable {
    public let references: [PushRefResult]
    public let atomic: Bool

    public init(references: [PushRefResult], atomic: Bool) {
        self.references = references
        self.atomic = atomic
    }
}
