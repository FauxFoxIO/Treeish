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

public enum GitSignatureFormat: String, Sendable, Hashable, Codable {
    case openPGP
    case x509
    case ssh
}

public struct GitSigningOptions: Sendable, Hashable, Codable {
    public let keyID: String?
    public let format: GitSignatureFormat?

    public init(
        keyID: String? = nil,
        format: GitSignatureFormat? = nil
    ) throws {
        guard keyID?.utf8.count ?? 0 <= 4_096,
              keyID?.contains("\0") != true,
              keyID?.contains("\n") != true else {
            throw TreeishError.invalidSignature
        }
        self.keyID = keyID
        self.format = format
    }
}

public enum GitSignedObjectType: String, Sendable, Hashable, Codable {
    case commit
    case tag
}

public struct GitObjectSignature: Sendable, Hashable, Codable {
    public let format: GitSignatureFormat
    public let bytes: [UInt8]

    public init(format: GitSignatureFormat, bytes: [UInt8]) throws {
        guard !bytes.isEmpty,
              bytes.count <= 16 * 1024 * 1024,
              !bytes.contains(0) else {
            throw TreeishError.invalidSignature
        }
        self.format = format
        self.bytes = bytes
    }
}

public struct GitSigningChallenge: Sendable, Hashable {
    public let objectType: GitSignedObjectType
    public let objectFormat: ObjectHashAlgorithm
    public let payload: [UInt8]
    public let options: GitSigningOptions

    public init(
        objectType: GitSignedObjectType,
        objectFormat: ObjectHashAlgorithm,
        payload: [UInt8],
        options: GitSigningOptions
    ) {
        self.objectType = objectType
        self.objectFormat = objectFormat
        self.payload = payload
        self.options = options
    }
}

public protocol GitObjectSigner: Sendable {
    func sign(_ challenge: GitSigningChallenge) async throws -> GitObjectSignature
}

public struct GitSignedObject: Sendable, Hashable, Codable {
    public let objectID: ObjectID
    public let objectType: GitSignedObjectType
    public let signedPayload: [UInt8]
    public let signature: GitObjectSignature

    public init(
        objectID: ObjectID,
        objectType: GitSignedObjectType,
        signedPayload: [UInt8],
        signature: GitObjectSignature
    ) {
        self.objectID = objectID
        self.objectType = objectType
        self.signedPayload = signedPayload
        self.signature = signature
    }
}

public enum GitSignatureVerification: Sendable, Hashable, Codable {
    case valid(signer: String?)
    case invalid(reason: String?)
    case unknownSigner(String?)
}

public protocol GitObjectSignatureVerifier: Sendable {
    func verify(_ object: GitSignedObject) async throws -> GitSignatureVerification
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
    public var objectSigner: (any GitObjectSigner)?
    public var signatureVerifier: (any GitObjectSignatureVerifier)?

    public init(
        credentials: (any GitCredentialProvider)? = nil,
        httpTransport: (any SmartHTTPTransport)? = nil,
        sshTransport: (any SSHGitTransport)? = nil,
        objectSigner: (any GitObjectSigner)? = nil,
        signatureVerifier: (any GitObjectSignatureVerifier)? = nil
    ) {
        self.credentials = credentials
        self.httpTransport = httpTransport
        self.sshTransport = sshTransport
        self.objectSigner = objectSigner
        self.signatureVerifier = signatureVerifier
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

public struct FetchRefspec: Sendable, Hashable, Codable,
    CustomStringConvertible {
    public let source: [UInt8]
    public let destination: [UInt8]?
    public let force: Bool
    public let negative: Bool

    public init(
        source: String,
        destination: String? = nil,
        force: Bool = false,
        negative: Bool = false
    ) throws {
        let sourceBytes = Array(source.utf8)
        let destinationBytes = destination.map { Array($0.utf8) }
        try Self.validate(
            source: sourceBytes,
            destination: destinationBytes,
            force: force,
            negative: negative
        )
        self.source = sourceBytes
        self.destination = destinationBytes
        self.force = force
        self.negative = negative
    }

    public init(_ value: String) throws {
        var bytes = Array(value.utf8)
        let negative = bytes.first == 0x5e
        let force = bytes.first == 0x2b
        if negative || force {
            bytes.removeFirst()
        }
        let separators = bytes.indices.filter { bytes[$0] == 0x3a }
        guard separators.count <= 1 else {
            throw TreeishError.invalidRefName
        }
        let source: [UInt8]
        let destination: [UInt8]?
        if let separator = separators.first {
            source = Array(bytes[..<separator])
            let suffix = Array(bytes[bytes.index(after: separator)...])
            destination = suffix.isEmpty ? nil : suffix
        } else {
            source = bytes
            destination = nil
        }
        try Self.validate(
            source: source,
            destination: destination,
            force: force,
            negative: negative
        )
        self.source = source
        self.destination = destination
        self.force = force
        self.negative = negative
    }

    public var description: String {
        let prefix = negative ? "^" : (force ? "+" : "")
        let source = String(decoding: source, as: UTF8.self)
        return prefix + source + (destination.map {
            ":" + String(decoding: $0, as: UTF8.self)
        } ?? "")
    }

    private static func validate(
        source: [UInt8],
        destination: [UInt8]?,
        force: Bool,
        negative: Bool
    ) throws {
        let sourceWildcards = source.filter { $0 == 0x2a }.count
        let destinationWildcards = destination?
            .filter { $0 == 0x2a }.count ?? 0
        guard !source.isEmpty,
              sourceWildcards <= 1,
              negative || destinationWildcards == sourceWildcards,
              !(negative && (force || destination != nil)) else {
            throw TreeishError.invalidRefName
        }
        _ = try RefName(
            validating: source.map { $0 == 0x2a ? 0x78 : $0 }
        )
        if let destination {
            _ = try RefName(
                validating: destination.map { $0 == 0x2a ? 0x78 : $0 }
            )
        }
    }
}

extension FetchRefspec {
    var advertisementPrefix: [UInt8] {
        Array(source.prefix { $0 != 0x2a })
    }

    func matches(_ reference: [UInt8]) -> Bool {
        Self.capture(reference, pattern: source) != nil
    }

    func localReference(for remoteReference: [UInt8]) throws -> RefName? {
        guard let destination,
              let capture = Self.capture(
                  remoteReference,
                  pattern: source
              ) else {
            return nil
        }
        return try RefName(
            validating: Self.expanding(destination, with: capture)
        )
    }

    func remoteReference(for localReference: [UInt8]) -> [UInt8]? {
        guard let destination,
              let capture = Self.capture(
                  localReference,
                  pattern: destination
              ) else {
            return nil
        }
        return Self.expanding(source, with: capture)
    }

    private static func capture(
        _ reference: [UInt8],
        pattern: [UInt8]
    ) -> [UInt8]? {
        guard let wildcard = pattern.firstIndex(of: 0x2a) else {
            return reference == pattern ? [] : nil
        }
        let prefix = pattern[..<wildcard]
        let suffix = pattern[pattern.index(after: wildcard)...]
        guard reference.count >= prefix.count + suffix.count,
              reference.starts(with: prefix),
              reference.suffix(suffix.count).elementsEqual(suffix) else {
            return nil
        }
        return Array(
            reference[prefix.count..<(reference.count - suffix.count)]
        )
    }

    private static func expanding(
        _ pattern: [UInt8],
        with capture: [UInt8]
    ) -> [UInt8] {
        guard let wildcard = pattern.firstIndex(of: 0x2a) else {
            return pattern
        }
        return Array(pattern[..<wildcard])
            + capture
            + Array(pattern[pattern.index(after: wildcard)...])
    }
}

public enum GitShallowRequest: Sendable, Hashable, Codable {
    case depth(UInt32)
    case since(secondsSinceEpoch: Int64)
    case excluding([String])
    case sinceExcluding(secondsSinceEpoch: Int64, revisions: [String])
    case unshallow
}

public struct FetchRequest: Sendable, Hashable {
    public let remote: RemoteURL
    public let remoteName: String
    public let refspecs: [FetchRefspec]
    public let filter: GitObjectFilter?
    public let shallow: GitShallowRequest?
    public let prune: Bool
    let requiresMatch: Bool

    public init(
        remote: RemoteURL,
        remoteName: String = "origin",
        refspecs: [FetchRefspec] = [],
        filter: GitObjectFilter? = nil,
        shallow: GitShallowRequest? = nil,
        prune: Bool = false
    ) throws {
        guard !remoteName.isEmpty,
              remoteName.allSatisfy({
                  $0.isLetter || $0.isNumber || "-_.".contains($0)
              }),
              Self.valid(shallow)
        else { throw TreeishError.invalidRefName }
        self.remote = remote
        self.remoteName = remoteName
        requiresMatch = !refspecs.isEmpty
        if refspecs.isEmpty {
            self.refspecs = [
                try FetchRefspec(
                    "+refs/heads/*:refs/remotes/\(remoteName)/*"
                ),
                try FetchRefspec("+refs/tags/*:refs/tags/*"),
            ]
        } else {
            self.refspecs = refspecs
        }
        self.filter = filter
        self.shallow = shallow
        self.prune = prune
    }

    fileprivate static func valid(_ request: GitShallowRequest?) -> Bool {
        switch request {
        case .none, .some(.unshallow):
            return true
        case .some(.depth(let depth)):
            return depth > 0 && depth <= UInt32(Int32.max)
        case .some(.since(let seconds)):
            return seconds >= 0
        case .some(.excluding(let revisions)):
            return !revisions.isEmpty
                && revisions.count <= 1_024
                && revisions.allSatisfy {
                    !$0.isEmpty
                        && $0.utf8.count <= 4_096
                        && !$0.contains("\0")
                        && !$0.contains("\n")
                }
        case .some(.sinceExcluding(let seconds, let revisions)):
            return seconds >= 0
                && !revisions.isEmpty
                && revisions.count <= 1_024
                && revisions.allSatisfy {
                    !$0.isEmpty
                        && $0.utf8.count <= 4_096
                        && !$0.contains("\0")
                        && !$0.contains("\n")
                }
        }
    }
}

public struct FetchResult: Sendable, Hashable, Codable {
    public let receivedObjects: Int
    public let updatedReferences: [RefUpdateResult]
    public let remoteHead: RefName?
    public let shallowBoundaries: [ObjectID]
    public let prunedReferences: [RefName]

    public init(
        receivedObjects: Int,
        updatedReferences: [RefUpdateResult],
        remoteHead: RefName?,
        shallowBoundaries: [ObjectID] = [],
        prunedReferences: [RefName] = []
    ) {
        self.receivedObjects = receivedObjects
        self.updatedReferences = updatedReferences
        self.remoteHead = remoteHead
        self.shallowBoundaries = shallowBoundaries
        self.prunedReferences = prunedReferences
    }
}

public enum CloneMode: String, Sendable, Hashable, Codable {
    case normal
    case bare
    case mirror
}

public struct CloneRequest: Sendable, Hashable {
    public let remote: RemoteURL
    public let destination: GitPath
    public let branch: RefName?
    public let remoteName: String
    public let filter: GitObjectFilter?
    public let shallow: GitShallowRequest?
    public let mode: CloneMode

    public init(
        remote: RemoteURL,
        destination: GitPath,
        branch: RefName? = nil,
        remoteName: String = "origin",
        filter: GitObjectFilter? = nil,
        shallow: GitShallowRequest? = nil,
        mode: CloneMode = .normal
    ) throws {
        guard branch == nil || branch?.description.hasPrefix("refs/heads/") == true,
              mode == .normal || branch == nil,
              mode != .mirror || (filter == nil && shallow == nil),
              !remoteName.isEmpty,
              remoteName.allSatisfy({ $0.isLetter || $0.isNumber || "-_ .".contains($0) }),
              !remoteName.contains(" "),
              FetchRequest.valid(shallow)
        else { throw TreeishError.invalidRefName }
        self.remote = remote
        self.destination = destination
        self.branch = branch
        self.remoteName = remoteName
        self.filter = filter
        self.shallow = shallow
        self.mode = mode
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
