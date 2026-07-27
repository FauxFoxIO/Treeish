public struct TreeishResourceLimits: Sendable, Hashable, Codable {
    public var maximumObjectBytes: Int
    public var maximumPathBytes: Int
    public var maximumConfigBytes: Int
    public var maximumDeltaDepth: Int
    public var maximumPackBytes: Int
    public var maximumTransactionBytes: Int

    public init(
        maximumObjectBytes: Int = 512 * 1024 * 1024,
        maximumPathBytes: Int = 4 * 1024,
        maximumConfigBytes: Int = 16 * 1024 * 1024,
        maximumDeltaDepth: Int = 64,
        maximumPackBytes: Int = 2 * 1024 * 1024 * 1024,
        maximumTransactionBytes: Int = 512 * 1024 * 1024
    ) {
        self.maximumObjectBytes = maximumObjectBytes
        self.maximumPathBytes = maximumPathBytes
        self.maximumConfigBytes = maximumConfigBytes
        self.maximumDeltaDepth = maximumDeltaDepth
        self.maximumPackBytes = maximumPackBytes
        self.maximumTransactionBytes = maximumTransactionBytes
    }
}
