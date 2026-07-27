import Foundation
import TreeishCore
import TreeishFileSystem

public enum GitIndexError: Error, Sendable, Equatable {
    case invalidSignature
    case unsupportedVersion(UInt32)
    case corrupt
    case checksumMismatch
    case unsupportedExtension(String)
}

public struct GitIndexEntry: Sendable, Hashable {
    public let path: [UInt8]
    public let objectID: [UInt8]
    public let mode: UInt32
    public let size: UInt32
    public let modificationSeconds: UInt32
    public let modificationNanoseconds: UInt32
    public let stage: UInt8

    public init(
        path: [UInt8],
        objectID: [UInt8],
        mode: UInt32,
        size: UInt32,
        modificationSeconds: UInt32,
        modificationNanoseconds: UInt32,
        stage: UInt8 = 0
    ) throws {
        guard !path.isEmpty,
              !path.contains(0),
              objectID.count == 20,
              stage <= 3
        else {
            throw GitIndexError.corrupt
        }
        self.path = path
        self.objectID = objectID
        self.mode = mode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.stage = stage
    }
}
public struct GitIndex: Sendable, Hashable {
    public var entries: [GitIndexEntry]

    public init(entries: [GitIndexEntry] = []) {
        self.entries = entries.sorted {
            if $0.path == $1.path { return $0.stage < $1.stage }
            return $0.path.lexicographicallyPrecedes($1.path)
        }
    }

    public static func decode(_ data: [UInt8]) throws -> GitIndex {
        guard data.count >= 12 + 20 else { throw GitIndexError.corrupt }
        let content = Array(data.dropLast(20))
        guard SHA1.hash(content) == Array(data.suffix(20)) else {
            throw GitIndexError.checksumMismatch
        }
        var reader = CheckedByteReader(content)
        guard Array(try reader.read(count: 4)) == Array("DIRC".utf8) else {
            throw GitIndexError.invalidSignature
        }
        let version = try reader.readUInt32BE()
        guard version == 2 else {
            throw GitIndexError.unsupportedVersion(version)
        }
        let count = try reader.readUInt32BE()
        guard count <= 10_000_000 else { throw GitIndexError.corrupt }
        var entries: [GitIndexEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            let entryStart = reader.offset
            let mtimeSeconds: UInt32
            let mtimeNanoseconds: UInt32
            _ = try reader.readUInt32BE()
            _ = try reader.readUInt32BE()
            mtimeSeconds = try reader.readUInt32BE()
            mtimeNanoseconds = try reader.readUInt32BE()
            _ = try reader.readUInt32BE()
            _ = try reader.readUInt32BE()
            let mode = try reader.readUInt32BE()
            _ = try reader.readUInt32BE()
            _ = try reader.readUInt32BE()
            let size = try reader.readUInt32BE()
            let objectID = Array(try reader.read(count: 20))
            let flagsHigh = try reader.readByte()
            let flagsLow = try reader.readByte()
            let flags = UInt16(flagsHigh) << 8 | UInt16(flagsLow)
            guard flags & 0x4000 == 0 else {
                throw GitIndexError.unsupportedExtension("extended entry flags")
            }
            let stage = UInt8((flags >> 12) & 0x3)
            var path: [UInt8] = []
            while true {
                let byte = try reader.readByte()
                if byte == 0 { break }
                path.append(byte)
            }
            let consumed = reader.offset - entryStart
            let padding = (8 - (consumed % 8)) % 8
            let paddingBytes = try reader.read(count: padding)
            guard paddingBytes.allSatisfy({ $0 == 0 }) else {
                throw GitIndexError.corrupt
            }
            entries.append(
                try GitIndexEntry(
                    path: path,
                    objectID: objectID,
                    mode: mode,
                    size: size,
                    modificationSeconds: mtimeSeconds,
                    modificationNanoseconds: mtimeNanoseconds,
                    stage: stage
                )
            )
        }
        guard reader.remainingCount == 0 else {
            let signature = try reader.read(count: min(4, reader.remainingCount))
            throw GitIndexError.unsupportedExtension(
                String(decoding: signature, as: UTF8.self)
            )
        }
        return GitIndex(entries: entries)
    }

    public func encode() -> [UInt8] {
        var writer = CheckedByteWriter()
        writer.append(contentsOf: "DIRC".utf8)
        writer.appendUInt32BE(2)
        writer.appendUInt32BE(UInt32(entries.count))
        for entry in entries {
            let entryStart = writer.bytes.count
            writer.appendUInt32BE(0)
            writer.appendUInt32BE(0)
            writer.appendUInt32BE(entry.modificationSeconds)
            writer.appendUInt32BE(entry.modificationNanoseconds)
            writer.appendUInt32BE(0)
            writer.appendUInt32BE(0)
            writer.appendUInt32BE(entry.mode)
            writer.appendUInt32BE(0)
            writer.appendUInt32BE(0)
            writer.appendUInt32BE(entry.size)
            writer.append(contentsOf: entry.objectID)
            let pathLength = min(entry.path.count, 0x0fff)
            let flags = UInt16(pathLength) | UInt16(entry.stage) << 12
            writer.append(UInt8((flags >> 8) & 0xff))
            writer.append(UInt8(flags & 0xff))
            writer.append(contentsOf: entry.path)
            writer.append(0)
            while (writer.bytes.count - entryStart) % 8 != 0 {
                writer.append(0)
            }
        }
        return writer.bytes + SHA1.hash(writer.bytes)
    }
}

public struct GitIndexStore: Sendable {
    private let gitDirectory: RootDirectory

    public init(gitDirectory: RootDirectory) {
        self.gitDirectory = gitDirectory
    }

    public func read() throws -> GitIndex {
        guard try gitDirectory.exists(["index"]) else {
            return GitIndex()
        }
        return try GitIndex.decode(
            gitDirectory.read(["index"], limit: 512 * 1024 * 1024)
        )
    }

    public func write(_ index: GitIndex) throws {
        try gitDirectory.writeAtomically(index.encode(), to: ["index"])
    }
}
