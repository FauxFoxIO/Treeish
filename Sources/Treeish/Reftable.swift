import Foundation
import TreeishCore
import TreeishFileSystem

enum ReftableError: Error, Sendable, Equatable {
    case invalidStack
    case invalidTable
    case unsupportedVersion(UInt8)
    case hashMismatch
    case resourceLimitExceeded
}

enum ReftableReferenceValue: Sendable, Hashable {
    case deletion
    case direct(ObjectID, peeled: ObjectID?)
    case symbolic(RefName)
}

struct ReftableReferenceRecord: Sendable, Hashable {
    let name: RefName
    let updateIndex: UInt64
    let value: ReftableReferenceValue
}

struct ReftableStack: Sendable {
    private static let maximumTableBytes = 256 * 1024 * 1024
    private static let maximumTables = 65_536
    private static let maximumRecordsPerTable = 4_000_000

    let directory: RootDirectory
    let objectFormat: ObjectHashAlgorithm

    func references() throws -> [RefName: ReftableReferenceValue] {
        let tables = try tableNames()
        var result: [RefName: ReftableReferenceValue] = [:]
        var seen: Set<RefName> = []
        for table in tables.reversed() {
            let bytes = try directory.read(
                ["reftable", table],
                limit: Self.maximumTableBytes
            )
            for record in try ReftableReader(
                bytes: bytes,
                expectedObjectFormat: objectFormat,
                maximumRecords: Self.maximumRecordsPerTable
            ).referenceRecords() where seen.insert(record.name).inserted {
                result[record.name] = record.value
            }
        }
        return result
    }

    func reference(_ name: RefName) throws -> ReftableReferenceValue {
        let tables = try tableNames()
        for table in tables.reversed() {
            let bytes = try directory.read(
                ["reftable", table],
                limit: Self.maximumTableBytes
            )
            if let record = try ReftableReader(
                bytes: bytes,
                expectedObjectFormat: objectFormat,
                maximumRecords: Self.maximumRecordsPerTable
            ).referenceRecords().first(where: { $0.name == name }) {
                return record.value
            }
        }
        throw TreeishError.referenceNotFound
    }

    private func tableNames() throws -> [String] {
        let bytes = try directory.read(
            ["reftable", "tables.list"],
            limit: 16 * 1024 * 1024
        )
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw ReftableError.invalidStack
        }
        let names = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard names.count <= Self.maximumTables,
              names.allSatisfy(Self.isValidTableName)
        else { throw ReftableError.invalidStack }
        return names
    }

    private static func isValidTableName(_ name: String) -> Bool {
        !name.isEmpty &&
        (name.hasSuffix(".ref") || name.hasSuffix(".log")) &&
        !name.contains("/") &&
        !name.contains("\\") &&
        name != "." &&
        name != ".." &&
        !name.utf8.contains(0)
    }
}

private struct ReftableReader {
    private static let magic = Array("REFT".utf8)

    let bytes: [UInt8]
    let expectedObjectFormat: ObjectHashAlgorithm
    let maximumRecords: Int

    func referenceRecords() throws -> [ReftableReferenceRecord] {
        let header = try parseHeader(at: 0)
        guard header.objectFormat == expectedObjectFormat else {
            throw ReftableError.hashMismatch
        }
        let footerLength = header.version == 1 ? 68 : 72
        guard bytes.count >= header.length + footerLength else {
            throw ReftableError.invalidTable
        }
        let footerOffset = bytes.count - footerLength
        let footer = try parseFooter(at: footerOffset, expected: header)
        guard header.length < footerOffset else { return [] }

        let candidates = [
            footer.refIndexPosition,
            footer.objectPosition,
            footer.logPosition,
            UInt64(footerOffset),
        ].filter { $0 > 0 }
        guard let sectionEndValue = candidates.min(),
              sectionEndValue <= UInt64(footerOffset),
              let sectionEnd = Int(exactly: sectionEndValue)
        else { throw ReftableError.invalidTable }

        var records: [ReftableReferenceRecord] = []
        var blockStart = 0
        var blockHeader = header.length
        while blockHeader < sectionEnd {
            guard bytes[blockHeader] == 0x72 else { break }
            let blockLength = try readUInt24(at: blockHeader + 1)
            let blockEnd = blockStart + blockLength
            guard blockLength >= (blockStart == 0 ? header.length + 6 : 6),
                  blockEnd <= sectionEnd else {
                throw ReftableError.invalidTable
            }
            try parseReferenceBlock(
                start: blockStart,
                headerOffset: blockHeader,
                end: blockEnd,
                tableHeader: header,
                into: &records
            )
            guard records.count <= maximumRecords else {
                throw ReftableError.resourceLimitExceeded
            }
            if header.blockSize == 0 {
                blockStart = blockEnd
            } else {
                guard blockStart <= Int.max - header.blockSize else {
                    throw ReftableError.invalidTable
                }
                blockStart += header.blockSize
            }
            blockHeader = blockStart
        }
        return records
    }

    private func parseReferenceBlock(
        start: Int,
        headerOffset: Int,
        end: Int,
        tableHeader: Header,
        into records: inout [ReftableReferenceRecord]
    ) throws {
        guard end >= 2 else { throw ReftableError.invalidTable }
        let restartCount = Int(try readUInt16(at: end - 2))
        guard restartCount > 0,
              restartCount <= 65_535,
              restartCount <= (end - start - 2) / 3
        else { throw ReftableError.invalidTable }
        let restartBytes = restartCount * 3
        let recordsEnd = end - 2 - restartBytes
        var priorRestart = -1
        for index in 0..<restartCount {
            let offset = try readUInt24(at: recordsEnd + index * 3)
            guard offset > priorRestart,
                  offset >= headerOffset + 4 - start,
                  offset < recordsEnd - start
            else { throw ReftableError.invalidTable }
            priorRestart = offset
        }

        var offset = headerOffset + 4
        var priorName: [UInt8] = []
        while offset < recordsEnd {
            let prefixLength = try readVarint(at: &offset)
            let typeAndLength = try readVarint(at: &offset)
            guard prefixLength <= UInt64(priorName.count),
                  let suffixLength = Int(exactly: typeAndLength >> 3),
                  suffixLength <= recordsEnd - offset
            else { throw ReftableError.invalidTable }
            let valueType = UInt8(typeAndLength & 0x07)
            let nameBytes = Array(priorName.prefix(Int(prefixLength))) +
                bytes[offset..<(offset + suffixLength)]
            offset += suffixLength
            let updateDelta = try readVarint(at: &offset)
            guard tableHeader.minimumUpdateIndex <= UInt64.max - updateDelta,
                  let name = try? RefName(validating: nameBytes)
            else { throw ReftableError.invalidTable }

            let value: ReftableReferenceValue
            switch valueType {
            case 0:
                value = .deletion
            case 1, 2:
                let objectBytes = try readBytes(
                    count: tableHeader.objectFormat.byteCount,
                    at: &offset,
                    before: recordsEnd
                )
                let object = try ObjectID(bytes: objectBytes)
                let peeled: ObjectID?
                if valueType == 2 {
                    peeled = try ObjectID(bytes: readBytes(
                        count: tableHeader.objectFormat.byteCount,
                        at: &offset,
                        before: recordsEnd
                    ))
                } else {
                    peeled = nil
                }
                value = .direct(object, peeled: peeled)
            case 3:
                let length = try readVarint(at: &offset)
                guard let count = Int(exactly: length) else {
                    throw ReftableError.invalidTable
                }
                let target = try readBytes(
                    count: count,
                    at: &offset,
                    before: recordsEnd
                )
                guard let reference = try? RefName(validating: target) else {
                    throw ReftableError.invalidTable
                }
                value = .symbolic(reference)
            default:
                throw ReftableError.invalidTable
            }
            records.append(ReftableReferenceRecord(
                name: name,
                updateIndex: tableHeader.minimumUpdateIndex + updateDelta,
                value: value
            ))
            priorName = nameBytes
        }
        guard offset == recordsEnd else { throw ReftableError.invalidTable }
    }

    private func parseHeader(at offset: Int) throws -> Header {
        guard offset >= 0, offset <= bytes.count - 24,
              Array(bytes[offset..<(offset + 4)]) == Self.magic
        else { throw ReftableError.invalidTable }
        let version = bytes[offset + 4]
        guard version == 1 || version == 2 else {
            throw ReftableError.unsupportedVersion(version)
        }
        let length = version == 1 ? 24 : 28
        guard offset <= bytes.count - length else {
            throw ReftableError.invalidTable
        }
        let format: ObjectHashAlgorithm
        if version == 1 {
            format = .sha1
        } else {
            let hashID = Array(bytes[(offset + 24)..<(offset + 28)])
            switch hashID {
            case Array("sha1".utf8): format = .sha1
            case Array("s256".utf8): format = .sha256
            default: throw ReftableError.invalidTable
            }
        }
        return Header(
            version: version,
            length: length,
            blockSize: try readUInt24(at: offset + 5),
            minimumUpdateIndex: try readUInt64(at: offset + 8),
            maximumUpdateIndex: try readUInt64(at: offset + 16),
            objectFormat: format
        )
    }

    private func parseFooter(at offset: Int, expected: Header) throws -> Footer {
        let header = try parseHeader(at: offset)
        guard header == expected else { throw ReftableError.invalidTable }
        let crcOffset = bytes.count - 4
        guard crcOffset > offset,
              try readUInt32(at: crcOffset) == CRC32.hash(bytes[offset..<crcOffset])
        else { throw ReftableError.invalidTable }
        var cursor = offset + header.length
        let refIndex = try readUInt64(at: cursor)
        cursor += 8
        let object = try readUInt64(at: cursor)
        cursor += 8
        let objectIndex = try readUInt64(at: cursor)
        cursor += 8
        let log = try readUInt64(at: cursor)
        cursor += 8
        let logIndex = try readUInt64(at: cursor)
        return Footer(
            refIndexPosition: refIndex,
            objectPosition: object >> 5,
            objectIndexPosition: objectIndex,
            logPosition: log,
            logIndexPosition: logIndex
        )
    }

    private func readBytes(
        count: Int,
        at offset: inout Int,
        before end: Int
    ) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset <= end - count else {
            throw ReftableError.invalidTable
        }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    private func readVarint(at offset: inout Int) throws -> UInt64 {
        guard offset < bytes.count else { throw ReftableError.invalidTable }
        var value = UInt64(bytes[offset] & 0x7f)
        var byte = bytes[offset]
        offset += 1
        var count = 1
        while byte & 0x80 != 0 {
            guard count < 10, offset < bytes.count,
                  value < (UInt64.max >> 7)
            else { throw ReftableError.invalidTable }
            byte = bytes[offset]
            offset += 1
            value = ((value + 1) << 7) | UInt64(byte & 0x7f)
            count += 1
        }
        return value
    }

    private func readUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= bytes.count - 2 else {
            throw ReftableError.invalidTable
        }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func readUInt24(at offset: Int) throws -> Int {
        guard offset >= 0, offset <= bytes.count - 3 else {
            throw ReftableError.invalidTable
        }
        return (Int(bytes[offset]) << 16) |
            (Int(bytes[offset + 1]) << 8) |
            Int(bytes[offset + 2])
    }

    private func readUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else {
            throw ReftableError.invalidTable
        }
        return bytes[offset..<(offset + 4)].reduce(into: UInt32.zero) {
            $0 = ($0 << 8) | UInt32($1)
        }
    }

    private func readUInt64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= bytes.count - 8 else {
            throw ReftableError.invalidTable
        }
        return bytes[offset..<(offset + 8)].reduce(into: UInt64.zero) {
            $0 = ($0 << 8) | UInt64($1)
        }
    }

    private struct Header: Equatable {
        let version: UInt8
        let length: Int
        let blockSize: Int
        let minimumUpdateIndex: UInt64
        let maximumUpdateIndex: UInt64
        let objectFormat: ObjectHashAlgorithm
    }

    private struct Footer {
        let refIndexPosition: UInt64
        let objectPosition: UInt64
        let objectIndexPosition: UInt64
        let logPosition: UInt64
        let logIndexPosition: UInt64
    }
}

private enum CRC32 {
    static func hash(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320)
            }
        }
        return crc ^ 0xffff_ffff
    }
}
