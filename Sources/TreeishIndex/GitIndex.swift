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
    public let assumeValid: Bool
    public let skipWorktree: Bool
    public let intentToAdd: Bool

    public init(
        path: [UInt8],
        objectID: [UInt8],
        mode: UInt32,
        size: UInt32,
        modificationSeconds: UInt32,
        modificationNanoseconds: UInt32,
        stage: UInt8 = 0,
        assumeValid: Bool = false,
        skipWorktree: Bool = false,
        intentToAdd: Bool = false
    ) throws {
        guard !path.isEmpty,
              !path.contains(0),
              (objectID.count == GitHashAlgorithm.sha1.byteCount ||
                objectID.count == GitHashAlgorithm.sha256.byteCount),
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
        self.assumeValid = assumeValid
        self.skipWorktree = skipWorktree
        self.intentToAdd = intentToAdd
    }
}
public struct GitIndex: Sendable, Hashable {
    public let version: UInt32
    public let objectFormat: GitHashAlgorithm
    public var entries: [GitIndexEntry]

    public init(
        version: UInt32 = 2,
        objectFormat: GitHashAlgorithm = .sha1,
        entries: [GitIndexEntry] = []
    ) {
        precondition((2...4).contains(version))
        precondition(entries.allSatisfy {
            $0.objectID.count == objectFormat.byteCount
        })
        self.version = version
        self.objectFormat = objectFormat
        self.entries = entries.sorted {
            if $0.path == $1.path { return $0.stage < $1.stage }
            return $0.path.lexicographicallyPrecedes($1.path)
        }
    }

    public static func decode(
        _ data: [UInt8],
        objectFormat: GitHashAlgorithm = .sha1
    ) throws -> GitIndex {
        let hashLength = objectFormat.byteCount
        guard data.count >= 12 + hashLength else {
            throw GitIndexError.corrupt
        }
        let content = Array(data.dropLast(hashLength))
        guard objectFormat.hash(content) == Array(data.suffix(hashLength)) else {
            throw GitIndexError.checksumMismatch
        }
        var reader = CheckedByteReader(content)
        guard Array(try reader.read(count: 4)) == Array("DIRC".utf8) else {
            throw GitIndexError.invalidSignature
        }
        let version = try reader.readUInt32BE()
        guard (2...4).contains(version) else {
            throw GitIndexError.unsupportedVersion(version)
        }
        let count = try reader.readUInt32BE()
        guard count <= 10_000_000 else { throw GitIndexError.corrupt }
        var entries: [GitIndexEntry] = []
        entries.reserveCapacity(Int(count))
        var previousPath: [UInt8] = []
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
            let objectID = Array(try reader.read(count: hashLength))
            let flagsHigh = try reader.readByte()
            let flagsLow = try reader.readByte()
            let flags = UInt16(flagsHigh) << 8 | UInt16(flagsLow)
            let extendedFlags: UInt16
            if flags & 0x4000 != 0 {
                guard version >= 3 else { throw GitIndexError.corrupt }
                extendedFlags =
                    UInt16(try reader.readByte()) << 8 |
                    UInt16(try reader.readByte())
                guard extendedFlags & ~UInt16(0x6000) == 0 else {
                    throw GitIndexError.unsupportedExtension(
                        "unknown extended entry flags"
                    )
                }
            } else {
                extendedFlags = 0
            }
            let stage = UInt8((flags >> 12) & 0x3)
            var path: [UInt8] = []
            if version == 4 {
                let remove = try decodeIndexVariableInteger(&reader)
                guard remove <= previousPath.count else {
                    throw GitIndexError.corrupt
                }
                path = Array(previousPath.dropLast(remove))
            }
            while true {
                let byte = try reader.readByte()
                if byte == 0 { break }
                path.append(byte)
            }
            if version < 4 {
                let consumed = reader.offset - entryStart
                let padding = (8 - (consumed % 8)) % 8
                let paddingBytes = try reader.read(count: padding)
                guard paddingBytes.allSatisfy({ $0 == 0 }) else {
                    throw GitIndexError.corrupt
                }
            }
            entries.append(
                try GitIndexEntry(
                    path: path,
                    objectID: objectID,
                    mode: mode,
                    size: size,
                    modificationSeconds: mtimeSeconds,
                    modificationNanoseconds: mtimeNanoseconds,
                    stage: stage,
                    assumeValid: flags & 0x8000 != 0,
                    skipWorktree: extendedFlags & 0x4000 != 0,
                    intentToAdd: extendedFlags & 0x2000 != 0
                )
            )
            previousPath = path
        }
        while reader.remainingCount > 0 {
            guard reader.remainingCount >= 8 else { throw GitIndexError.corrupt }
            let signature = Array(try reader.read(count: 4))
            let size = try reader.readUInt32BE()
            guard UInt64(size) <= UInt64(reader.remainingCount) else {
                throw GitIndexError.corrupt
            }
            _ = try reader.read(count: Int(size))
            if let first = signature.first, first >= 0x61, first <= 0x7a {
                throw GitIndexError.unsupportedExtension(
                    String(decoding: signature, as: UTF8.self)
                )
            }
        }
        return GitIndex(
            version: version,
            objectFormat: objectFormat,
            entries: entries
        )
    }

    public func encode() -> [UInt8] {
        var writer = CheckedByteWriter()
        writer.append(contentsOf: "DIRC".utf8)
        writer.appendUInt32BE(version)
        writer.appendUInt32BE(UInt32(entries.count))
        var previousPath: [UInt8] = []
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
            let hasExtendedFlags = entry.skipWorktree || entry.intentToAdd
            let flags = UInt16(pathLength) |
                UInt16(entry.stage) << 12 |
                (hasExtendedFlags ? 0x4000 : 0) |
                (entry.assumeValid ? 0x8000 : 0)
            writer.append(UInt8((flags >> 8) & 0xff))
            writer.append(UInt8(flags & 0xff))
            if hasExtendedFlags {
                let extended: UInt16 =
                    (entry.skipWorktree ? 0x4000 : 0) |
                    (entry.intentToAdd ? 0x2000 : 0)
                writer.append(UInt8((extended >> 8) & 0xff))
                writer.append(UInt8(extended & 0xff))
            }
            if version == 4 {
                let shared = zip(previousPath, entry.path).prefix {
                    $0 == $1
                }.count
                writer.append(contentsOf: Self.encodeIndexVariableInteger(
                    previousPath.count - shared
                ))
                writer.append(contentsOf: entry.path.dropFirst(shared))
            } else {
                writer.append(contentsOf: entry.path)
            }
            writer.append(0)
            if version < 4 {
                while (writer.bytes.count - entryStart) % 8 != 0 {
                    writer.append(0)
                }
            }
            previousPath = entry.path
        }
        return writer.bytes + objectFormat.hash(writer.bytes)
    }

    private static func decodeIndexVariableInteger(
        _ reader: inout CheckedByteReader
    ) throws -> Int {
        var value = 0
        while true {
            let byte = try reader.readByte()
            guard value <= (Int.max >> 7) else { throw GitIndexError.corrupt }
            value = (value << 7) | Int(byte & 0x7f)
            if byte & 0x80 == 0 { return value }
            guard value < Int.max else { throw GitIndexError.corrupt }
            value += 1
        }
    }

    private static func encodeIndexVariableInteger(_ input: Int) -> [UInt8] {
        var value = input
        var bytes = [UInt8(value & 0x7f)]
        while value >= 0x80 {
            value = (value >> 7) - 1
            bytes.append(UInt8(value & 0x7f) | 0x80)
        }
        return Array(bytes.reversed())
    }
}

public struct GitIndexStore: Sendable {
    private let gitDirectory: RootDirectory
    private let objectFormat: GitHashAlgorithm

    public init(
        gitDirectory: RootDirectory,
        objectFormat: GitHashAlgorithm = .sha1
    ) {
        self.gitDirectory = gitDirectory
        self.objectFormat = objectFormat
    }

    public func read() throws -> GitIndex {
        guard try gitDirectory.exists(["index"]) else {
            return GitIndex(objectFormat: objectFormat)
        }
        return try GitIndex.decode(
            gitDirectory.read(["index"], limit: 512 * 1024 * 1024),
            objectFormat: objectFormat
        )
    }

    public func write(_ index: GitIndex) throws {
        try gitDirectory.writeAtomically(index.encode(), to: ["index"])
    }
}
