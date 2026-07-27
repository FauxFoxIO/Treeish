import Compression

public enum ZlibError: Error, Sendable, Equatable {
    case compressionFailed
    case decompressionFailed
    case invalidHeader
    case presetDictionaryUnsupported
    case checksumMismatch
    case resourceLimitExceeded
}

public enum Zlib {
    public struct DecompressedPrefix: Sendable, Hashable {
        public let bytes: [UInt8]
        public let consumedInputBytes: Int

        public init(bytes: [UInt8], consumedInputBytes: Int) {
            self.bytes = bytes
            self.consumedInputBytes = consumedInputBytes
        }
    }

    public static func compress(_ input: [UInt8]) throws -> [UInt8] {
        let compressed = try process(
            input,
            operation: COMPRESSION_STREAM_ENCODE,
            maximumOutputBytes: nil
        )
        let checksum = adler32(input)
        return [0x78, 0x5e]
            + compressed.bytes
            + [
                UInt8(truncatingIfNeeded: checksum >> 24),
                UInt8(truncatingIfNeeded: checksum >> 16),
                UInt8(truncatingIfNeeded: checksum >> 8),
                UInt8(truncatingIfNeeded: checksum),
            ]
    }

    public static func decompress(
        _ input: [UInt8],
        maximumOutputBytes: Int = 512 * 1024 * 1024
    ) throws -> [UInt8] {
        try decompressPrefix(
            input,
            maximumOutputBytes: maximumOutputBytes
        ).bytes
    }

    public static func decompressPrefix(
        _ input: [UInt8],
        maximumOutputBytes: Int = 512 * 1024 * 1024
    ) throws -> DecompressedPrefix {
        guard maximumOutputBytes >= 0 else {
            throw ZlibError.resourceLimitExceeded
        }
        guard input.count >= 6 else {
            throw ZlibError.decompressionFailed
        }

        let compressionMethodAndFlags = input[0]
        let additionalFlags = input[1]
        let header = (UInt16(compressionMethodAndFlags) << 8)
            | UInt16(additionalFlags)
        guard compressionMethodAndFlags & 0x0f == 8,
              compressionMethodAndFlags >> 4 <= 7,
              header.isMultiple(of: 31)
        else {
            throw ZlibError.invalidHeader
        }
        guard additionalFlags & 0x20 == 0 else {
            throw ZlibError.presetDictionaryUnsupported
        }

        let compressedAndFollowingBytes = Array(input.dropFirst(2))
        let deflate = try DeflateStreamParser.parse(
            compressedAndFollowingBytes,
            maximumOutputBytes: maximumOutputBytes
        )
        let decompressed = try process(
            Array(compressedAndFollowingBytes.prefix(deflate.compressedByteCount)),
            operation: COMPRESSION_STREAM_DECODE,
            maximumOutputBytes: maximumOutputBytes
        )
        guard decompressed.bytes.count == deflate.uncompressedByteCount else {
            throw ZlibError.decompressionFailed
        }
        let checksumStart = 2 + deflate.compressedByteCount
        guard checksumStart <= input.count - 4 else {
            throw ZlibError.decompressionFailed
        }
        let expectedChecksum =
            (UInt32(input[checksumStart]) << 24)
            | (UInt32(input[checksumStart + 1]) << 16)
            | (UInt32(input[checksumStart + 2]) << 8)
            | UInt32(input[checksumStart + 3])
        guard expectedChecksum == adler32(decompressed.bytes) else {
            throw ZlibError.checksumMismatch
        }

        return DecompressedPrefix(
            bytes: decompressed.bytes,
            consumedInputBytes: checksumStart + 4
        )
    }

    private struct StreamResult {
        let bytes: [UInt8]
        let consumedInputBytes: Int
    }

    private static func process(
        _ input: [UInt8],
        operation: compression_stream_operation,
        maximumOutputBytes: Int?
    ) throws -> StreamResult {
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }

        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        let initialization = compression_stream_init(
            &stream,
            operation,
            COMPRESSION_ZLIB
        )
        guard initialization == COMPRESSION_STATUS_OK else {
            throw operation == COMPRESSION_STREAM_ENCODE
                ? ZlibError.compressionFailed
                : ZlibError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var source = input
        if source.isEmpty {
            source.append(0)
        }
        var output: [UInt8] = []
        return try source.withUnsafeBytes { sourceBuffer in
            guard let sourceAddress = sourceBuffer
                .bindMemory(to: UInt8.self)
                .baseAddress
            else {
                throw operation == COMPRESSION_STREAM_ENCODE
                    ? ZlibError.compressionFailed
                    : ZlibError.decompressionFailed
            }
            stream.src_ptr = sourceAddress
            stream.src_size = input.count

            while true {
                let capacity: Int
                if let maximumOutputBytes {
                    capacity = output.count == maximumOutputBytes
                        ? 1
                        : min(64 * 1024, maximumOutputBytes - output.count)
                } else {
                    capacity = 64 * 1024
                }
                var chunk = [UInt8](repeating: 0, count: capacity)
                let sourceBytesBefore = stream.src_size
                let status = chunk.withUnsafeMutableBytes { destination in
                    stream.dst_ptr = destination
                        .bindMemory(to: UInt8.self)
                        .baseAddress ?? placeholder
                    stream.dst_size = capacity
                    return compression_stream_process(
                        &stream,
                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    )
                }
                let produced = capacity - stream.dst_size
                output.append(contentsOf: chunk.prefix(produced))

                if let maximumOutputBytes,
                   output.count > maximumOutputBytes {
                    throw ZlibError.resourceLimitExceeded
                }
                if status == COMPRESSION_STATUS_END {
                    return StreamResult(
                        bytes: output,
                        consumedInputBytes: input.count - stream.src_size
                    )
                }
                guard status == COMPRESSION_STATUS_OK,
                      produced > 0 || stream.src_size < sourceBytesBefore
                else {
                    throw operation == COMPRESSION_STREAM_ENCODE
                        ? ZlibError.compressionFailed
                        : ZlibError.decompressionFailed
                }
            }
        }
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let modulus: UInt32 = 65_521
        var first: UInt32 = 1
        var second: UInt32 = 0
        for byte in bytes {
            first = (first + UInt32(byte)) % modulus
            second = (second + first) % modulus
        }
        return (second << 16) | first
    }
}
