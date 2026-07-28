import Foundation

public enum CapabilityReason: Sendable, Hashable, Codable, CustomStringConvertible {
    case rootIsReadOnly
    case repositoryFormat(Int)
    case objectFormat(ObjectHashAlgorithm)
    case requiredExtension(String)
    case refStorage(String)
    case indexFormat(String)
    case interruptedTransaction(String)

    public var description: String {
        switch self {
        case .rootIsReadOnly: "the granted root is read-only"
        case .repositoryFormat(let version): "repository format \(version) is not writable"
        case .objectFormat(let format): "object format \(format.rawValue) is not writable"
        case .requiredExtension(let name): "required extension \(name) is unsupported"
        case .refStorage(let storage): "ref storage \(storage) is unsupported"
        case .indexFormat(let detail): "index format is unsupported: \(detail)"
        case .interruptedTransaction(let detail): "recovery is required: \(detail)"
        }
    }
}
public enum RepositoryAccess: Sendable, Hashable, Codable {
    case readWrite
    case readOnly(reason: CapabilityReason)
    case metadataOnly(reason: CapabilityReason)
}

public enum RefStorageFormat: String, Sendable, Hashable, Codable {
    case files
    case reftable
}

public enum RepositoryOperationCapability: String, Sendable, Hashable, Codable {
    case readObjects
    case checkIntegrity
    case listTrees
    case readConfiguration
    case writeConfiguration
    case writeObjects
    case readRefs
    case updateRefs
    case resolveRevisions
    case readReflogs
    case createCommit
    case status
    case diff
    case inspectConflicts
    case stage
    case restore
    case checkout
    case reset
    case branchesAndTags
    case fetch
    case push
    case merge
    case sequencer
    case stash
    case submodules
    case bundles
    case linkedWorktrees
}

public struct IndexCapabilities: Sendable, Hashable, Codable {
    public let version: Int?
    public let canRead: Bool
    public let canWrite: Bool

    public init(version: Int?, canRead: Bool, canWrite: Bool) {
        self.version = version
        self.canRead = canRead
        self.canWrite = canWrite
    }
}

public struct RepositoryExtensionCapability: Sendable, Hashable, Codable {
    public let name: String
    public let value: String
    public let understood: Bool

    public init(name: String, value: String, understood: Bool) {
        self.name = name
        self.value = value
        self.understood = understood
    }
}

public struct RepositoryRestriction: Sendable, Hashable, Codable {
    public let reason: CapabilityReason

    public init(reason: CapabilityReason) {
        self.reason = reason
    }
}

public struct RepositoryCapabilities: Sendable, Hashable, Codable {
    public let access: RepositoryAccess
    public let objectFormat: ObjectHashAlgorithm
    public let refStorage: RefStorageFormat
    public let isShallow: Bool
    public let usesAlternates: Bool
    public let hasMultiPackIndex: Bool
    public let promisorRemotes: [String]
    public let index: IndexCapabilities
    public let repositoryExtensions: [RepositoryExtensionCapability]
    public let operations: Set<RepositoryOperationCapability>
    public let restrictions: [RepositoryRestriction]

    public init(
        access: RepositoryAccess,
        objectFormat: ObjectHashAlgorithm,
        refStorage: RefStorageFormat,
        isShallow: Bool,
        usesAlternates: Bool,
        hasMultiPackIndex: Bool,
        promisorRemotes: [String],
        index: IndexCapabilities,
        repositoryExtensions: [RepositoryExtensionCapability],
        operations: Set<RepositoryOperationCapability>,
        restrictions: [RepositoryRestriction]
    ) {
        self.access = access
        self.objectFormat = objectFormat
        self.refStorage = refStorage
        self.isShallow = isShallow
        self.usesAlternates = usesAlternates
        self.hasMultiPackIndex = hasMultiPackIndex
        self.promisorRemotes = promisorRemotes
        self.index = index
        self.repositoryExtensions = repositoryExtensions
        self.operations = operations
        self.restrictions = restrictions
    }
}
