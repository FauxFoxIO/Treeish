import CZlib
import Foundation

public enum ZlibError: Error, Sendable, Equatable {
    case compressionFailed(Int32)
    case decompressionFailed(Int32)
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

    public static func compress(_ input: [UInt8], level: Int32 = Z_DEFAULT_COMPRESSION) throws -> [UInt8] {
        let bound = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(bound))
        var outputLength = bound
        let status = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                compress2(
                    outputBuffer.bindMemory(to: Bytef.self).baseAddress,
                    &outputLength,
                    inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                    uLong(input.count),
                    level
                )
            }
        }
        guard status == Z_OK else { throw ZlibError.compressionFailed(status) }
        output.removeSubrange(Int(outputLength)..<output.count)
        return output
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
        var stream = z_stream()
        let initialization = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialization == Z_OK else {
            throw ZlibError.decompressionFailed(initialization)
        }
        defer { inflateEnd(&stream) }

        return try input.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer(
                mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(input.count)
            var output: [UInt8] = []
            let chunkSize = 64 * 1024
            var status = Z_OK
            while status == Z_OK {
                guard output.count <= maximumOutputBytes - chunkSize else {
                    throw ZlibError.resourceLimitExceeded
                }
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                output.append(contentsOf: chunk.prefix(produced))
            }
            guard status == Z_STREAM_END else {
                throw ZlibError.decompressionFailed(status)
            }
            return DecompressedPrefix(
                bytes: output,
                consumedInputBytes: Int(stream.total_in)
            )
        }
    }
}
