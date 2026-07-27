import Foundation

public struct GitOperationID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public enum GitProgressPhase: String, Sendable, Hashable, Codable {
    case discovery
    case negotiation
    case counting
    case compression
    case transfer
    case receiving
    case resolvingDeltas
    case validating
    case quarantining
    case indexing
    case updatingRefs
    case planningCheckout
    case updatingWorktree
    case updatingIndex
    case reconciling
    case completed
}

public struct GitDiagnostic: Sendable, Hashable, Codable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct GitProgressEvent: Sendable, Hashable, Codable {
    public let operationID: GitOperationID
    public let phase: GitProgressPhase
    public let completedUnits: Int64?
    public let totalUnits: Int64?
    public let message: GitDiagnostic?

    public init(
        operationID: GitOperationID,
        phase: GitProgressPhase,
        completedUnits: Int64? = nil,
        totalUnits: Int64? = nil,
        message: GitDiagnostic? = nil
    ) {
        self.operationID = operationID
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.message = message
    }
}

public struct GitOperation<Result: Sendable>: Sendable {
    public let id: GitOperationID
    public let events: AsyncStream<GitProgressEvent>
    private let task: Task<Result, Error>

    internal init(
        phase: GitProgressPhase,
        operation: @escaping @Sendable () async throws -> Result
    ) {
        let identifier = GitOperationID()
        id = identifier
        let (stream, continuation) = AsyncStream<GitProgressEvent>.makeStream()
        events = stream
        task = Task {
            continuation.yield(
                GitProgressEvent(operationID: identifier, phase: phase)
            )
            do {
                let value = try await operation()
                continuation.yield(
                    GitProgressEvent(operationID: identifier, phase: .completed)
                )
                continuation.finish()
                return value
            } catch {
                continuation.finish()
                throw error
            }
        }
    }

    public func value() async throws -> Result {
        try await task.value
    }

    public func cancel() {
        task.cancel()
    }
}
