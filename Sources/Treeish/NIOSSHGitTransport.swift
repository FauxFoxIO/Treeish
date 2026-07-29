import Crypto
import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices

public enum SSHAuthentication: Sendable, Equatable {
    case password(String)
    case ed25519PrivateKey([UInt8])
}

public enum SSHAuthenticationDisposition: Sendable, Equatable {
    case use(SSHAuthentication)
    case unavailable
    case cancel
}

public protocol SSHAuthenticationProvider: Sendable {
    func authentication(
        for endpoint: SSHRemoteEndpoint,
        availableMethods: Set<SSHAuthenticationMethod>
    ) async throws -> SSHAuthenticationDisposition
}

public enum SSHAuthenticationMethod: String, Sendable, Hashable, Codable {
    case password
    case publicKey
}

public struct SSHHostKey: Sendable, Hashable, Codable {
    public let algorithm: String
    public let openSSHPublicKey: String
    public let sha256Fingerprint: String

    public init(
        algorithm: String,
        openSSHPublicKey: String,
        sha256Fingerprint: String
    ) {
        self.algorithm = algorithm
        self.openSSHPublicKey = openSSHPublicKey
        self.sha256Fingerprint = sha256Fingerprint
    }
}

public protocol SSHHostKeyVerifier: Sendable {
    func accept(
        hostKey: SSHHostKey,
        for endpoint: SSHRemoteEndpoint
    ) async throws -> Bool
}

public struct NIOSSHGitTransportConfiguration: Sendable, Hashable, Codable {
    public var connectTimeoutSeconds: Int64
    public var maximumOutputBytes: Int

    public init(
        connectTimeoutSeconds: Int64 = 30,
        maximumOutputBytes: Int = 256 * 1024 * 1024
    ) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public final class NIOSSHGitTransport: SSHGitTransport, @unchecked Sendable {
    private let authenticationProvider: any SSHAuthenticationProvider
    private let hostKeyVerifier: any SSHHostKeyVerifier
    private let configuration: NIOSSHGitTransportConfiguration

    public init(
        authenticationProvider: any SSHAuthenticationProvider,
        hostKeyVerifier: any SSHHostKeyVerifier,
        configuration: NIOSSHGitTransportConfiguration = .init()
    ) {
        self.authenticationProvider = authenticationProvider
        self.hostKeyVerifier = hostKeyVerifier
        self.configuration = configuration
    }

    public func open(
        _ request: SSHGitSessionRequest
    ) async throws -> any SSHGitSession {
        try Task.checkCancellation()
        let group = NIOTSEventLoopGroup(loopCount: 1)
        let authentication = NIOSSHAuthenticationDelegate(
            endpoint: request.endpoint,
            provider: authenticationProvider
        )
        let verification = NIOSSHHostVerificationDelegate(
            endpoint: request.endpoint,
            verifier: hostKeyVerifier
        )
        let channel = try await NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.seconds(configuration.connectTimeoutSeconds))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: authentication,
                                serverAuthDelegate: verification
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }
            }
            .connect(host: request.endpoint.host, port: request.endpoint.port)
            .get()
        do {
            let stream = NIOSSHGitStreamHandler(
                command: Self.command(for: request),
                maximumOutputBytes: configuration.maximumOutputBytes
            )
            let child = try await channel.pipeline.handler(
                type: NIOSSHHandler.self
            ).flatMap { ssh in
                let childPromise = channel.eventLoop.makePromise(
                    of: Channel.self
                )
                ssh.createChannel(childPromise) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(
                            NIOSSHGitTransportError.invalidChannelType
                        )
                    }
                    return child.pipeline.addHandler(stream)
                }
                return childPromise.futureResult
            }.get()
            return NIOSSHGitSessionImplementation(
                connection: channel,
                channel: child,
                group: group,
                stream: stream
            )
        } catch {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private static func command(for request: SSHGitSessionRequest) -> String {
        let quoted = request.endpoint.repositoryPath
            .replacingOccurrences(of: "'", with: "'\\''")
        return "\(request.service.rawValue) '\(quoted)'"
    }
}

public enum NIOSSHGitTransportError: Error, Sendable, Equatable {
    case authenticationUnavailable
    case hostKeyRejected
    case invalidPrivateKey
    case invalidChannelType
    case remoteFailure(Int)
    case outputLimitExceeded
    case incompleteAdvertisement
}

private final class NIOSSHAuthenticationDelegate:
    NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: SSHRemoteEndpoint
    private let provider: any SSHAuthenticationProvider
    private let lock = NSLock()
    private var attempted: Set<SSHAuthenticationMethod> = []

    init(
        endpoint: SSHRemoteEndpoint,
        provider: any SSHAuthenticationProvider
    ) {
        self.endpoint = endpoint
        self.provider = provider
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let methods = Set<SSHAuthenticationMethod>([
            availableMethods.contains(.password)
                ? SSHAuthenticationMethod.password : nil,
            availableMethods.contains(.publicKey)
                ? SSHAuthenticationMethod.publicKey : nil,
        ].compactMap { $0 })
        lock.lock()
        let remaining = methods.subtracting(attempted)
        attempted.formUnion(remaining)
        lock.unlock()
        guard !remaining.isEmpty else {
            nextChallengePromise.succeed(nil)
            return
        }
        Task {
            do {
                switch try await provider.authentication(
                    for: endpoint,
                    availableMethods: remaining
                ) {
                case .use(.password(let password))
                    where remaining.contains(.password):
                    nextChallengePromise.succeed(.init(
                        username: endpoint.username,
                        serviceName: "ssh-connection",
                        offer: .password(.init(password: password))
                    ))
                case .use(.ed25519PrivateKey(let bytes))
                    where remaining.contains(.publicKey):
                    guard let key = try? Curve25519.Signing.PrivateKey(
                        rawRepresentation: bytes
                    ) else {
                        nextChallengePromise.fail(
                            NIOSSHGitTransportError.invalidPrivateKey
                        )
                        return
                    }
                    nextChallengePromise.succeed(.init(
                        username: endpoint.username,
                        serviceName: "ssh-connection",
                        offer: .privateKey(.init(
                            privateKey: NIOSSHPrivateKey(ed25519Key: key)
                        ))
                    ))
                case .cancel:
                    nextChallengePromise.fail(CancellationError())
                case .unavailable, .use:
                    nextChallengePromise.succeed(nil)
                }
            } catch {
                nextChallengePromise.fail(error)
            }
        }
    }
}

private final class NIOSSHHostVerificationDelegate:
    NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: SSHRemoteEndpoint
    private let verifier: any SSHHostKeyVerifier

    init(endpoint: SSHRemoteEndpoint, verifier: any SSHHostKeyVerifier) {
        self.endpoint = endpoint
        self.verifier = verifier
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let encoded = String(openSSHPublicKey: hostKey)
        let parts = encoded.split(separator: " ", maxSplits: 1)
        let wire = parts.count == 2
            ? Data(base64Encoded: String(parts[1])) ?? Data()
            : Data()
        let fingerprint = Data(SHA256.hash(data: wire)).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let value = SSHHostKey(
            algorithm: parts.first.map(String.init) ?? "unknown",
            openSSHPublicKey: encoded,
            sha256Fingerprint: "SHA256:\(fingerprint)"
        )
        Task {
            do {
                guard try await verifier.accept(
                    hostKey: value,
                    for: endpoint
                ) else {
                    validationCompletePromise.fail(
                        NIOSSHGitTransportError.hostKeyRejected
                    )
                    return
                }
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }
}

private final class NIOSSHGitStreamHandler:
    ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let maximumOutputBytes: Int
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var advertisementWaiters: [CheckedContinuation<[UInt8], Error>] = []
    private var completionWaiters: [CheckedContinuation<[UInt8], Error>] = []
    private var advertisementEnd: Int?
    private var error: Error?
    private var completed = false

    init(command: String, maximumOutputBytes: Int) {
        self.command = command
        self.maximumOutputBytes = maximumOutputBytes
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
            promise: nil
        )
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = value.data else { return }
        append(Array(buffer.readableBytesView), context: context)
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus,
           status.exitStatus != 0 {
            fail(
                NIOSSHGitTransportError.remoteFailure(status.exitStatus),
                context: context
            )
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    func advertisement() async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let error {
                    lock.unlock()
                    continuation.resume(throwing: error)
                } else if let advertisementEnd {
                    let result = Array(bytes[..<advertisementEnd])
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    advertisementWaiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func completion() async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let error {
                    lock.unlock()
                    continuation.resume(throwing: error)
                } else if completed {
                    let start = advertisementEnd ?? 0
                    let result = Array(bytes[start...])
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    completionWaiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func append(_ newBytes: [UInt8], context: ChannelHandlerContext) {
        lock.lock()
        guard error == nil else {
            lock.unlock()
            return
        }
        guard bytes.count <= maximumOutputBytes - newBytes.count else {
            lock.unlock()
            fail(NIOSSHGitTransportError.outputLimitExceeded, context: context)
            return
        }
        bytes += newBytes
        if advertisementEnd == nil,
           let end = Self.firstFlushPacketEnd(in: bytes) {
            advertisementEnd = end
            let result = Array(bytes[..<end])
            let waiters = advertisementWaiters
            advertisementWaiters = []
            lock.unlock()
            waiters.forEach { $0.resume(returning: result) }
            return
        }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        completed = true
        let start = advertisementEnd ?? 0
        let result = Array(bytes[start...])
        let advertisement = advertisementWaiters
        let completion = completionWaiters
        advertisementWaiters = []
        completionWaiters = []
        let missingAdvertisement = advertisementEnd == nil
        lock.unlock()
        if missingAdvertisement {
            advertisement.forEach {
                $0.resume(
                    throwing: NIOSSHGitTransportError.incompleteAdvertisement
                )
            }
        }
        completion.forEach { $0.resume(returning: result) }
    }

    private func fail(_ value: Error, context: ChannelHandlerContext) {
        lock.lock()
        guard error == nil else {
            lock.unlock()
            return
        }
        error = value
        let waiters = advertisementWaiters + completionWaiters
        advertisementWaiters = []
        completionWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(throwing: value) }
        context.close(promise: nil)
    }

    private func cancel() {
        lock.lock()
        error = CancellationError()
        let waiters = advertisementWaiters + completionWaiters
        advertisementWaiters = []
        completionWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }

    private static func firstFlushPacketEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index..<(index + 4)].elementsEqual([0x30, 0x30, 0x30, 0x30]) {
            return index + 4
        }
        return nil
    }
}

private actor NIOSSHGitSessionImplementation: SSHGitSession {
    private let connection: Channel
    private let channel: Channel
    private let group: NIOTSEventLoopGroup
    private let stream: NIOSSHGitStreamHandler
    private var didReadAdvertisement = false
    private var didExchange = false

    init(
        connection: Channel,
        channel: Channel,
        group: NIOTSEventLoopGroup,
        stream: NIOSSHGitStreamHandler
    ) {
        self.connection = connection
        self.channel = channel
        self.group = group
        self.stream = stream
    }

    func advertisement() async throws -> [UInt8] {
        guard !didReadAdvertisement else {
            throw NIOSSHGitTransportError.incompleteAdvertisement
        }
        didReadAdvertisement = true
        return try await stream.advertisement()
    }

    func exchange(_ request: [UInt8]) async throws -> [UInt8] {
        guard didReadAdvertisement, !didExchange else {
            throw NIOSSHGitTransportError.incompleteAdvertisement
        }
        didExchange = true
        var buffer = channel.allocator.buffer(capacity: request.count)
        buffer.writeBytes(request)
        try await channel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        ).get()
        try await channel.close(mode: .output).get()
        let response = try await stream.completion()
        try? await connection.close().get()
        try? await group.shutdownGracefully()
        return response
    }
}
