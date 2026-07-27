struct DeflateStreamBoundary: Sendable, Hashable {
    let compressedByteCount: Int
    let uncompressedByteCount: Int
}

enum DeflateStreamParser {
    static func parse(
        _ bytes: [UInt8],
        maximumOutputBytes: Int
    ) throws -> DeflateStreamBoundary {
        var reader = BitReader(bytes: bytes)
        var outputCount = 0
        var isFinal = false

        while !isFinal {
            isFinal = try reader.readBits(1) == 1
            switch try reader.readBits(2) {
            case 0:
                try readStoredBlock(
                    reader: &reader,
                    outputCount: &outputCount,
                    maximumOutputBytes: maximumOutputBytes
                )
            case 1:
                try readCompressedBlock(
                    reader: &reader,
                    literalLengths: fixedLiteralLengths,
                    distanceLengths: Array(repeating: 5, count: 32),
                    outputCount: &outputCount,
                    maximumOutputBytes: maximumOutputBytes
                )
            case 2:
                let trees = try readDynamicTrees(reader: &reader)
                try readCompressedBlock(
                    reader: &reader,
                    literalLengths: trees.literalLengths,
                    distanceLengths: trees.distanceLengths,
                    outputCount: &outputCount,
                    maximumOutputBytes: maximumOutputBytes
                )
            default:
                throw ZlibError.decompressionFailed
            }
        }

        return DeflateStreamBoundary(
            compressedByteCount: reader.consumedByteCount,
            uncompressedByteCount: outputCount
        )
    }

    private static let fixedLiteralLengths: [Int] = {
        var lengths = [Int](repeating: 0, count: 288)
        for index in 0...143 { lengths[index] = 8 }
        for index in 144...255 { lengths[index] = 9 }
        for index in 256...279 { lengths[index] = 7 }
        for index in 280...287 { lengths[index] = 8 }
        return lengths
    }()

    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    private static let lengthBases = [
        3, 4, 5, 6, 7, 8, 9, 10,
        11, 13, 15, 17,
        19, 23, 27, 31,
        35, 43, 51, 59,
        67, 83, 99, 115,
        131, 163, 195, 227,
        258,
    ]

    private static let lengthExtraBits = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1,
        2, 2, 2, 2,
        3, 3, 3, 3,
        4, 4, 4, 4,
        5, 5, 5, 5,
        0,
    ]

    private static let distanceBases = [
        1, 2, 3, 4,
        5, 7,
        9, 13,
        17, 25,
        33, 49,
        65, 97,
        129, 193,
        257, 385,
        513, 769,
        1_025, 1_537,
        2_049, 3_073,
        4_097, 6_145,
        8_193, 12_289,
        16_385, 24_577,
    ]

    private static let distanceExtraBits = [
        0, 0, 0, 0,
        1, 1,
        2, 2,
        3, 3,
        4, 4,
        5, 5,
        6, 6,
        7, 7,
        8, 8,
        9, 9,
        10, 10,
        11, 11,
        12, 12,
        13, 13,
    ]

    private static func readStoredBlock(
        reader: inout BitReader,
        outputCount: inout Int,
        maximumOutputBytes: Int
    ) throws {
        reader.alignToByte()
        let length = Int(try reader.readBits(16))
        let complement = Int(try reader.readBits(16))
        guard length ^ complement == 0xffff else {
            throw ZlibError.decompressionFailed
        }
        try reader.skipBytes(length)
        try addOutput(
            length,
            to: &outputCount,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private static func readDynamicTrees(
        reader: inout BitReader
    ) throws -> (literalLengths: [Int], distanceLengths: [Int]) {
        let literalCount = Int(try reader.readBits(5)) + 257
        let distanceCount = Int(try reader.readBits(5)) + 1
        let codeLengthCount = Int(try reader.readBits(4)) + 4

        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for offset in 0..<codeLengthCount {
            codeLengthLengths[codeLengthOrder[offset]] =
                Int(try reader.readBits(3))
        }
        let codeLengthTree = try HuffmanTree(lengths: codeLengthLengths)
        let totalCount = literalCount + distanceCount
        var lengths: [Int] = []
        lengths.reserveCapacity(totalCount)

        while lengths.count < totalCount {
            let symbol = try codeLengthTree.decode(reader: &reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else {
                    throw ZlibError.decompressionFailed
                }
                let count = Int(try reader.readBits(2)) + 3
                guard count <= totalCount - lengths.count else {
                    throw ZlibError.decompressionFailed
                }
                lengths.append(contentsOf: repeatElement(previous, count: count))
            case 17:
                let count = Int(try reader.readBits(3)) + 3
                guard count <= totalCount - lengths.count else {
                    throw ZlibError.decompressionFailed
                }
                lengths.append(contentsOf: repeatElement(0, count: count))
            case 18:
                let count = Int(try reader.readBits(7)) + 11
                guard count <= totalCount - lengths.count else {
                    throw ZlibError.decompressionFailed
                }
                lengths.append(contentsOf: repeatElement(0, count: count))
            default:
                throw ZlibError.decompressionFailed
            }
        }

        let literalLengths = Array(lengths[..<literalCount])
        guard literalLengths.indices.contains(256),
              literalLengths[256] > 0
        else {
            throw ZlibError.decompressionFailed
        }
        return (
            literalLengths,
            Array(lengths[literalCount...])
        )
    }

    private static func readCompressedBlock(
        reader: inout BitReader,
        literalLengths: [Int],
        distanceLengths: [Int],
        outputCount: inout Int,
        maximumOutputBytes: Int
    ) throws {
        let literalTree = try HuffmanTree(lengths: literalLengths)
        let distanceTree = distanceLengths.contains(where: { $0 > 0 })
            ? try HuffmanTree(lengths: distanceLengths)
            : nil

        while true {
            let symbol = try literalTree.decode(reader: &reader)
            switch symbol {
            case 0...255:
                try addOutput(
                    1,
                    to: &outputCount,
                    maximumOutputBytes: maximumOutputBytes
                )
            case 256:
                return
            case 257...285:
                let lengthIndex = symbol - 257
                let length = lengthBases[lengthIndex]
                    + Int(try reader.readBits(lengthExtraBits[lengthIndex]))
                guard let distanceTree else {
                    throw ZlibError.decompressionFailed
                }
                let distanceSymbol = try distanceTree.decode(reader: &reader)
                guard distanceBases.indices.contains(distanceSymbol) else {
                    throw ZlibError.decompressionFailed
                }
                let distance = distanceBases[distanceSymbol]
                    + Int(try reader.readBits(
                        distanceExtraBits[distanceSymbol]
                    ))
                guard distance <= outputCount else {
                    throw ZlibError.decompressionFailed
                }
                try addOutput(
                    length,
                    to: &outputCount,
                    maximumOutputBytes: maximumOutputBytes
                )
            default:
                throw ZlibError.decompressionFailed
            }
        }
    }

    private static func addOutput(
        _ count: Int,
        to outputCount: inout Int,
        maximumOutputBytes: Int
    ) throws {
        guard count <= maximumOutputBytes - outputCount else {
            throw ZlibError.resourceLimitExceeded
        }
        outputCount += count
    }
}

private struct BitReader {
    let bytes: [UInt8]
    private(set) var bitOffset = 0

    var consumedByteCount: Int {
        (bitOffset + 7) / 8
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
        guard count >= 0,
              count <= 24,
              bitOffset <= bytes.count * 8 - count
        else {
            throw ZlibError.decompressionFailed
        }
        var value: UInt32 = 0
        for shift in 0..<count {
            let byte = bytes[bitOffset / 8]
            let bit = (byte >> (bitOffset % 8)) & 1
            value |= UInt32(bit) << shift
            bitOffset += 1
        }
        return value
    }

    mutating func alignToByte() {
        bitOffset = (bitOffset + 7) & ~7
    }

    mutating func skipBytes(_ count: Int) throws {
        guard bitOffset.isMultiple(of: 8),
              count >= 0,
              count <= (bytes.count * 8 - bitOffset) / 8
        else {
            throw ZlibError.decompressionFailed
        }
        bitOffset += count * 8
    }
}

private struct HuffmanTree {
    private struct Code: Hashable {
        let length: Int
        let bits: UInt32
    }

    private let symbols: [Code: Int]
    private let maximumLength: Int

    init(lengths: [Int]) throws {
        guard let maximumLength = lengths.max(),
              maximumLength > 0,
              maximumLength <= 15
        else {
            throw ZlibError.decompressionFailed
        }
        var counts = [Int](repeating: 0, count: maximumLength + 1)
        for length in lengths {
            guard length >= 0, length <= maximumLength else {
                throw ZlibError.decompressionFailed
            }
            if length > 0 {
                counts[length] += 1
            }
        }

        var available = 1
        for length in 1...maximumLength {
            available = available * 2 - counts[length]
            guard available >= 0 else {
                throw ZlibError.decompressionFailed
            }
        }

        var nextCode = [Int](repeating: 0, count: maximumLength + 1)
        var code = 0
        if maximumLength > 1 {
            for length in 1..<maximumLength {
                code = (code + counts[length]) << 1
                nextCode[length + 1] = code
            }
        }

        var symbols: [Code: Int] = [:]
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let canonical = nextCode[length]
            nextCode[length] += 1
            let key = Code(
                length: length,
                bits: Self.reverse(canonical, count: length)
            )
            guard symbols.updateValue(symbol, forKey: key) == nil else {
                throw ZlibError.decompressionFailed
            }
        }
        self.symbols = symbols
        self.maximumLength = maximumLength
    }

    func decode(reader: inout BitReader) throws -> Int {
        var bits: UInt32 = 0
        for length in 1...maximumLength {
            bits |= try reader.readBits(1) << (length - 1)
            if let symbol = symbols[Code(length: length, bits: bits)] {
                return symbol
            }
        }
        throw ZlibError.decompressionFailed
    }

    private static func reverse(_ value: Int, count: Int) -> UInt32 {
        var source = value
        var reversed: UInt32 = 0
        for _ in 0..<count {
            reversed = (reversed << 1) | UInt32(source & 1)
            source >>= 1
        }
        return reversed
    }
}
