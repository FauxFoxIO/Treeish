import Foundation
import TreeishHTTP

public struct RemoteURL: Sendable, Hashable, Codable, CustomStringConvertible {
    public let url: URL

    public init(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw TreeishError.invalidPath
        }
        self.url = url
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

public struct RepositoryServices: Sendable {
    public var credentials: (any GitCredentialProvider)?
    public var httpTransport: (any SmartHTTPTransport)?

    public init(
        credentials: (any GitCredentialProvider)? = nil,
        httpTransport: (any SmartHTTPTransport)? = nil
    ) {
        self.credentials = credentials
        self.httpTransport = httpTransport
    }
}

public struct FetchRequest: Sendable, Hashable {
    public let remote: RemoteURL
    public let remoteName: String
    public let refNames: [RefName]

    public init(
        remote: RemoteURL,
        remoteName: String = "origin",
        refNames: [RefName] = []
    ) throws {
        guard !remoteName.isEmpty,
              remoteName.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) })
        else { throw TreeishError.invalidRefName }
        self.remote = remote
        self.remoteName = remoteName
        self.refNames = refNames
    }
}

public struct FetchResult: Sendable, Hashable, Codable {
    public let receivedObjects: Int
    public let updatedReferences: [RefUpdateResult]
    public let remoteHead: RefName?

    public init(
        receivedObjects: Int,
        updatedReferences: [RefUpdateResult],
        remoteHead: RefName?
    ) {
        self.receivedObjects = receivedObjects
        self.updatedReferences = updatedReferences
        self.remoteHead = remoteHead
    }
}

public struct CloneRequest: Sendable, Hashable {
    public let remote: RemoteURL
    public let destination: GitPath
    public let branch: RefName?
    public let remoteName: String

    public init(
        remote: RemoteURL,
        destination: GitPath,
        branch: RefName? = nil,
        remoteName: String = "origin"
    ) throws {
        guard branch == nil || branch?.description.hasPrefix("refs/heads/") == true,
              !remoteName.isEmpty,
              remoteName.allSatisfy({ $0.isLetter || $0.isNumber || "-_ .".contains($0) }),
              !remoteName.contains(" ")
        else { throw TreeishError.invalidRefName }
        self.remote = remote
        self.destination = destination
        self.branch = branch
        self.remoteName = remoteName
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

    public init(
        remote: RemoteURL,
        refspecs: [PushRefspec],
        requiresAtomic: Bool = false
    ) throws {
        guard !refspecs.isEmpty else { throw TreeishError.invalidRefName }
        self.remote = remote
        self.refspecs = refspecs
        self.requiresAtomic = requiresAtomic
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
