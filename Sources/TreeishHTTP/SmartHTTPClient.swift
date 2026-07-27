import Foundation
import TreeishProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SmartHTTPError: Error, Sendable, Equatable {
    case insecureURL
    case credentialInURL
    case invalidResponse
    case unexpectedStatus(Int)
    case invalidContentType
    case responseTooLarge
    case redirectRejected
}

public struct SmartHTTPResponse: Sendable, Hashable {
    public let body: [UInt8]
    public let contentType: String?
}

public struct SmartHTTPRequest: Sendable, Hashable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: [UInt8]

    public init(url: URL, method: String, headers: [String: String], body: [UInt8] = []) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct SmartHTTPTransportResponse: Sendable, Hashable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: [UInt8]
    public let finalURL: URL

    public init(statusCode: Int, headers: [String: String], body: [UInt8], finalURL: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}

public protocol SmartHTTPTransport: Sendable {
    func execute(_ request: SmartHTTPRequest) async throws -> SmartHTTPTransportResponse
}

public struct URLSessionSmartHTTPTransport: SmartHTTPTransport {
    public init() {}

    public func execute(_ value: SmartHTTPRequest) async throws -> SmartHTTPTransportResponse {
        var request = URLRequest(url: value.url)
        request.httpMethod = value.method
        request.httpBody = value.body.isEmpty ? nil : Data(value.body)
        for (name, value) in value.headers { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = RedirectGuard(origin: value.url)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw SmartHTTPError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return SmartHTTPTransportResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: Array(data),
            finalURL: finalURL
        )
    }
}

public struct SmartHTTPClient: Sendable {
    public var maximumResponseBytes: Int
    private let transport: any SmartHTTPTransport

    public init(
        maximumResponseBytes: Int = 2 * 1024 * 1024 * 1024,
        transport: any SmartHTTPTransport = URLSessionSmartHTTPTransport()
    ) {
        self.maximumResponseBytes = maximumResponseBytes
        self.transport = transport
    }

    public func advertisement(
        remote: URL,
        authorization: String? = nil,
        protocolVersion: Int? = nil
    ) async throws -> SmartHTTPResponse {
        let base = try validate(remote)
        var components = URLComponents(
            url: base.appendingPathComponent("info/refs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "service", value: "git-upload-pack")]
        guard let url = components?.url else { throw SmartHTTPError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/x-git-upload-pack-advertisement", forHTTPHeaderField: "Accept")
        request.setValue("git/2.0", forHTTPHeaderField: "User-Agent")
        if let protocolVersion {
            request.setValue("version=\(protocolVersion)", forHTTPHeaderField: "Git-Protocol")
        }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return try await perform(
            request,
            origin: base,
            expectedContentType: "application/x-git-upload-pack-advertisement"
        )
    }

    public func uploadPack(
        remote: URL,
        body: [UInt8],
        authorization: String? = nil
    ) async throws -> SmartHTTPResponse {
        let base = try validate(remote)
        var request = URLRequest(url: base.appendingPathComponent("git-upload-pack"))
        request.httpMethod = "POST"
        request.httpBody = Data(body)
        request.setValue("application/x-git-upload-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-upload-pack-result", forHTTPHeaderField: "Accept")
        request.setValue("git/2.0", forHTTPHeaderField: "User-Agent")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return try await perform(
            request,
            origin: base,
            expectedContentType: "application/x-git-upload-pack-result"
        )
    }

    public func receiveAdvertisement(
        remote: URL,
        authorization: String? = nil
    ) async throws -> SmartHTTPResponse {
        let base = try validate(remote)
        var components = URLComponents(
            url: base.appendingPathComponent("info/refs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "service", value: "git-receive-pack")]
        guard let url = components?.url else { throw SmartHTTPError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/x-git-receive-pack-advertisement", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return try await perform(
            request,
            origin: base,
            expectedContentType: "application/x-git-receive-pack-advertisement"
        )
    }

    public func receivePack(
        remote: URL,
        body: [UInt8],
        authorization: String? = nil
    ) async throws -> SmartHTTPResponse {
        let base = try validate(remote)
        var request = URLRequest(url: base.appendingPathComponent("git-receive-pack"))
        request.httpMethod = "POST"
        request.httpBody = Data(body)
        request.setValue("application/x-git-receive-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-receive-pack-result", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return try await perform(
            request,
            origin: base,
            expectedContentType: "application/x-git-receive-pack-result"
        )
    }

    private func perform(
        _ request: URLRequest,
        origin: URL,
        expectedContentType: String
    ) async throws -> SmartHTTPResponse {
        guard let url = request.url else { throw SmartHTTPError.invalidResponse }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name] = value }
        let response = try await transport.execute(SmartHTTPRequest(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: headers,
            body: request.httpBody.map(Array.init) ?? []
        ))
        guard response.finalURL.scheme?.lowercased() == origin.scheme?.lowercased(),
              response.finalURL.host?.lowercased() == origin.host?.lowercased(),
              response.finalURL.port == origin.port else {
            throw SmartHTTPError.redirectRejected
        }
        guard (200..<300).contains(response.statusCode) else {
            throw SmartHTTPError.unexpectedStatus(response.statusCode)
        }
        guard response.body.count <= maximumResponseBytes else {
            throw SmartHTTPError.responseTooLarge
        }
        let contentType = response.headers.first { $0.key.caseInsensitiveCompare("content-type") == .orderedSame }?.value
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard contentType == expectedContentType else {
            throw SmartHTTPError.invalidContentType
        }
        return SmartHTTPResponse(
            body: response.body,
            contentType: contentType
        )
    }

    private func validate(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw SmartHTTPError.insecureURL
        }
        guard url.user == nil, url.password == nil else {
            throw SmartHTTPError.credentialInURL
        }
        return url
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let scheme: String?
    private let host: String?
    private let port: Int?

    init(origin: URL) {
        scheme = origin.scheme?.lowercased()
        host = origin.host?.lowercased()
        port = origin.port
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == scheme,
              request.url?.host?.lowercased() == host,
              request.url?.port == port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
