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

struct ReftableLogRecord: Sendable, Hashable {
    let name: RefName
    let updateIndex: UInt64
    let entry: ReflogEntry?
}

enum ReftableExpectedValue: Sendable, Hashable {
    case any
    case missing
    case direct(ObjectID)
}

struct ReftableUpdate: Sendable, Hashable {
    let name: RefName
    let value: ReftableReferenceValue
    let expected: ReftableExpectedValue
    let reflog: ReflogMetadata?
    let reflogObjects: ReftableLogObjects?

    init(
        name: RefName,
        value: ReftableReferenceValue,
        expected: ReftableExpectedValue,
        reflog: ReflogMetadata?,
        reflogObjects: ReftableLogObjects? = nil
    ) {
        self.name = name
        self.value = value
        self.expected = expected
        self.reflog = reflog
        self.reflogObjects = reflogObjects
    }
}

struct ReftableLogObjects: Sendable, Hashable {
    let previous: ObjectID
    let current: ObjectID
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

    func reflog(_ name: RefName) throws -> [ReflogEntry] {
        let tables = try tableNames()
        var records: [ReftableLogRecord] = []
        for table in tables.reversed() {
            let bytes = try directory.read(
                ["reftable", table],
                limit: Self.maximumTableBytes
            )
            records += try ReftableReader(
                bytes: bytes,
                expectedObjectFormat: objectFormat,
                maximumRecords: Self.maximumRecordsPerTable
            ).logRecords().filter { $0.name == name }
            guard records.count <= Self.maximumRecordsPerTable else {
                throw ReftableError.resourceLimitExceeded
            }
        }
        return records
            .sorted { $0.updateIndex > $1.updateIndex }
            .compactMap(\.entry)
    }

    func append(_ updates: [ReftableUpdate]) throws {
        guard !updates.isEmpty,
              Set(updates.map(\.name)).count == updates.count
        else { throw ReftableError.invalidTable }
        let originalList: [UInt8]
        do {
            originalList = try directory.read(
                ["reftable", "tables.list"],
                limit: 16 * 1024 * 1024
            )
        } catch RootDirectoryError.notFound {
            originalList = []
        }
        let names = try tableNames(from: originalList)
        let current = try references(in: names)
        for update in updates {
            let existing = current[update.name]
            switch update.expected {
            case .any:
                break
            case .missing:
                guard existing == nil || existing == .deletion else {
                    throw TreeishError.referenceChanged
                }
            case .direct(let identifier):
                guard case .direct(let actual, _) = existing,
                      actual == identifier else {
                    throw TreeishError.referenceChanged
                }
            }
        }
        let prepared = updates.map { update in
            guard update.reflog != nil,
                  update.expected == .any,
                  case .direct(let prior, _) = current[update.name]
            else { return update }
            return ReftableUpdate(
                name: update.name,
                value: update.value,
                expected: .direct(prior),
                reflog: update.reflog,
                reflogObjects: update.reflogObjects
            )
        }
        let updateIndex = try nextUpdateIndex(in: names)
        let table = try ReftableWriter(
            objectFormat: objectFormat,
            updateIndex: updateIndex
        ).write(prepared)
        let filename = String(
            format: "0x%012llx-0x%012llx-%@.ref",
            updateIndex,
            updateIndex,
            String(UUID().uuidString.prefix(8)).lowercased()
        )
        try directory.writeAtomically(
            table,
            to: ["reftable", filename]
        )
        var replacement = originalList
        if !replacement.isEmpty, replacement.last != 0x0a {
            replacement.append(0x0a)
        }
        replacement.append(contentsOf: filename.utf8)
        replacement.append(0x0a)
        do {
            guard try directory.compareAndSwap(
                replacement,
                to: ["reftable", "tables.list"],
                expected: originalList.isEmpty ? nil : originalList,
                requireMissing: originalList.isEmpty
            ) else {
                _ = try? directory.removeAtomically(
                    ["reftable", filename],
                    expected: table
                )
                throw TreeishError.referenceChanged
            }
        } catch {
            _ = try? directory.removeAtomically(
                ["reftable", filename],
                expected: table
            )
            throw error
        }
    }

    private func tableNames() throws -> [String] {
        let bytes = try directory.read(
            ["reftable", "tables.list"],
            limit: 16 * 1024 * 1024
        )
        return try tableNames(from: bytes)
    }

    private func tableNames(from bytes: [UInt8]) throws -> [String] {
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

    private func references(
        in tables: [String]
    ) throws -> [RefName: ReftableReferenceValue] {
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

    private func nextUpdateIndex(in tables: [String]) throws -> UInt64 {
        var maximum: UInt64 = 0
        for table in tables {
            let bytes = try directory.read(
                ["reftable", table],
                limit: Self.maximumTableBytes
            )
            maximum = max(
                maximum,
                try ReftableReader(
                    bytes: bytes,
                    expectedObjectFormat: objectFormat,
                    maximumRecords: Self.maximumRecordsPerTable
                ).updateRange().maximum
            )
        }
        guard maximum < UInt64.max else {
            throw ReftableError.resourceLimitExceeded
        }
        return maximum + 1
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

    func updateRange() throws -> (minimum: UInt64, maximum: UInt64) {
        let header = try parseHeader(at: 0)
        guard header.objectFormat == expectedObjectFormat else {
            throw ReftableError.hashMismatch
        }
        return (header.minimumUpdateIndex, header.maximumUpdateIndex)
    }

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

    func logRecords() throws -> [ReftableLogRecord] {
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
        guard footer.logPosition > 0,
              footer.logPosition < UInt64(footerOffset),
              let firstBlock = Int(exactly: footer.logPosition)
        else {
            if footer.logPosition == 0 { return [] }
            throw ReftableError.invalidTable
        }
        let sectionEndValue = footer.logIndexPosition > 0
            ? min(footer.logIndexPosition, UInt64(footerOffset))
            : UInt64(footerOffset)
        guard let sectionEnd = Int(exactly: sectionEndValue),
              firstBlock < sectionEnd else {
            throw ReftableError.invalidTable
        }

        var records: [ReftableLogRecord] = []
        var blockStart = firstBlock
        while blockStart < sectionEnd {
            guard bytes[blockStart] == 0x67 else { break }
            let inflatedLength = try readUInt24(at: blockStart + 1)
            guard inflatedLength >= 6 else {
                throw ReftableError.invalidTable
            }
            let compressedStart = blockStart + 4
            let prefix = try Zlib.decompressPrefix(
                Array(bytes[compressedStart..<sectionEnd]),
                maximumOutputBytes: inflatedLength - 4
            )
            guard prefix.bytes.count == inflatedLength - 4 else {
                throw ReftableError.invalidTable
            }
            try parseLogBlock(
                [0x67, bytes[blockStart + 1], bytes[blockStart + 2], bytes[blockStart + 3]]
                    + prefix.bytes,
                tableHeader: header,
                into: &records
            )
            guard records.count <= maximumRecords else {
                throw ReftableError.resourceLimitExceeded
            }
            if header.blockSize == 0 {
                blockStart = compressedStart + prefix.consumedInputBytes
            } else {
                let next = ((blockStart / header.blockSize) + 1) * header.blockSize
                guard next > blockStart else { throw ReftableError.invalidTable }
                blockStart = next
            }
        }
        return records
    }

    private func parseLogBlock(
        _ block: [UInt8],
        tableHeader: Header,
        into records: inout [ReftableLogRecord]
    ) throws {
        let end = block.count
        let restartCount = Int(readUInt16(block, at: end - 2))
        guard restartCount > 0,
              restartCount <= (end - 2) / 3 else {
            throw ReftableError.invalidTable
        }
        let recordsEnd = end - 2 - restartCount * 3
        var priorRestart = -1
        for index in 0..<restartCount {
            let restart = Int(readUInt24(block, at: recordsEnd + index * 3))
            guard restart > priorRestart,
                  restart >= 4,
                  restart < recordsEnd else {
                throw ReftableError.invalidTable
            }
            priorRestart = restart
        }
        var offset = 4
        var priorKey: [UInt8] = []
        while offset < recordsEnd {
            let prefixLength = try readVarint(block, at: &offset)
            let typeAndLength = try readVarint(block, at: &offset)
            guard prefixLength <= UInt64(priorKey.count),
                  let suffixLength = Int(exactly: typeAndLength >> 3),
                  suffixLength <= recordsEnd - offset else {
                throw ReftableError.invalidTable
            }
            let valueType = UInt8(typeAndLength & 0x07)
            let key = Array(priorKey.prefix(Int(prefixLength)))
                + block[offset..<(offset + suffixLength)]
            offset += suffixLength
            guard key.count >= 9,
                  key[key.count - 9] == 0,
                  let name = try? RefName(
                    validating: Array(key.dropLast(9))
                  ) else {
                throw ReftableError.invalidTable
            }
            let reversedIndex = key.suffix(8).reduce(into: UInt64.zero) {
                $0 = ($0 << 8) | UInt64($1)
            }
            let updateIndex = UInt64.max - reversedIndex
            let entry: ReflogEntry?
            switch valueType {
            case 0:
                entry = nil
            case 1:
                let old = try ObjectID(bytes: readBytes(
                    block,
                    count: tableHeader.objectFormat.byteCount,
                    at: &offset,
                    before: recordsEnd
                ))
                let new = try ObjectID(bytes: readBytes(
                    block,
                    count: tableHeader.objectFormat.byteCount,
                    at: &offset,
                    before: recordsEnd
                ))
                let committerName = try readUTF8(block, at: &offset, before: recordsEnd)
                let email = try readUTF8(block, at: &offset, before: recordsEnd)
                let seconds = try readVarint(block, at: &offset)
                guard seconds <= UInt64(Int64.max),
                      offset <= recordsEnd - 2 else {
                    throw ReftableError.invalidTable
                }
                let zone = Int(Int16(bitPattern: readUInt16(block, at: offset)))
                offset += 2
                var message = try readUTF8(block, at: &offset, before: recordsEnd)
                if message.last == "\n" { message.removeLast() }
                entry = ReflogEntry(
                    previous: old,
                    current: new,
                    committer: Signature(
                        name: committerName,
                        email: email,
                        secondsSinceEpoch: Int64(seconds),
                        timeZoneOffsetMinutes: zone
                    ),
                    message: message
                )
            default:
                throw ReftableError.invalidTable
            }
            records.append(ReftableLogRecord(
                name: name,
                updateIndex: updateIndex,
                entry: entry
            ))
            priorKey = key
        }
        guard offset == recordsEnd else { throw ReftableError.invalidTable }
    }

    private func readVarint(_ source: [UInt8], at offset: inout Int) throws -> UInt64 {
        guard offset < source.count else { throw ReftableError.invalidTable }
        var value = UInt64(source[offset] & 0x7f)
        var byte = source[offset]
        offset += 1
        var count = 1
        while byte & 0x80 != 0 {
            guard count < 10, offset < source.count,
                  value < (UInt64.max >> 7) else {
                throw ReftableError.invalidTable
            }
            byte = source[offset]
            offset += 1
            value = ((value + 1) << 7) | UInt64(byte & 0x7f)
            count += 1
        }
        return value
    }

    private func readBytes(
        _ source: [UInt8],
        count: Int,
        at offset: inout Int,
        before end: Int
    ) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset <= end - count else {
            throw ReftableError.invalidTable
        }
        defer { offset += count }
        return Array(source[offset..<(offset + count)])
    }

    private func readUTF8(
        _ source: [UInt8],
        at offset: inout Int,
        before end: Int
    ) throws -> String {
        let length = try readVarint(source, at: &offset)
        guard let count = Int(exactly: length),
              let value = String(
                bytes: try readBytes(
                    source,
                    count: count,
                    at: &offset,
                    before: end
                ),
                encoding: .utf8
              ) else {
            throw ReftableError.invalidTable
        }
        return value
    }

    private func readUInt16(_ source: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(source[offset]) << 8) | UInt16(source[offset + 1])
    }

    private func readUInt24(_ source: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(source[offset]) << 16)
            | (UInt32(source[offset + 1]) << 8)
            | UInt32(source[offset + 2])
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

private struct ReftableWriter {
    let objectFormat: ObjectHashAlgorithm
    let updateIndex: UInt64

    func write(_ updates: [ReftableUpdate]) throws -> [UInt8] {
        let version: UInt8 = objectFormat == .sha1 ? 1 : 2
        let header = makeHeader(version: version)
        let sorted = updates.sorted {
            $0.name.bytes.lexicographicallyPrecedes($1.name.bytes)
        }
        var refBody: [UInt8] = []
        var refRestarts: [Int] = []
        var prior: [UInt8] = []
        for (index, update) in sorted.enumerated() {
            let restart = index.isMultiple(of: 16)
            let prefix = restart ? 0 : commonPrefix(prior, update.name.bytes)
            if restart { refRestarts.append(header.count + 4 + refBody.count) }
            appendVarint(UInt64(prefix), to: &refBody)
            let type: UInt64
            switch update.value {
            case .deletion: type = 0
            case .direct(_, nil): type = 1
            case .direct(_, .some): type = 2
            case .symbolic: type = 3
            }
            let suffix = update.name.bytes.dropFirst(prefix)
            appendVarint((UInt64(suffix.count) << 3) | type, to: &refBody)
            refBody.append(contentsOf: suffix)
            appendVarint(0, to: &refBody)
            switch update.value {
            case .deletion:
                break
            case .direct(let identifier, let peeled):
                guard identifier.algorithm == objectFormat,
                      peeled?.algorithm == nil || peeled?.algorithm == objectFormat
                else { throw ReftableError.hashMismatch }
                refBody.append(contentsOf: identifier.bytes)
                if let peeled { refBody.append(contentsOf: peeled.bytes) }
            case .symbolic(let target):
                appendVarint(UInt64(target.bytes.count), to: &refBody)
                refBody.append(contentsOf: target.bytes)
            }
            prior = update.name.bytes
        }
        guard !refRestarts.isEmpty else { throw ReftableError.invalidTable }
        var refBlock = [UInt8(0x72), 0, 0, 0] + refBody
        for offset in refRestarts {
            try appendUInt24(offset, to: &refBlock)
        }
        appendUInt16(UInt16(refRestarts.count), to: &refBlock)
        let refLength = header.count + refBlock.count
        guard refLength <= 0x00ff_ffff else {
            throw ReftableError.resourceLimitExceeded
        }
        setUInt24(refLength, in: &refBlock, at: 1)
        var output = header + refBlock

        let logged = sorted.filter { $0.reflog != nil }
        let logPosition: UInt64
        if logged.isEmpty {
            logPosition = 0
        } else {
            logPosition = UInt64(output.count)
            output.append(contentsOf: try makeLogBlock(logged))
        }
        var footer = header
        appendUInt64(0, to: &footer)
        appendUInt64(0, to: &footer)
        appendUInt64(0, to: &footer)
        appendUInt64(logPosition, to: &footer)
        appendUInt64(0, to: &footer)
        appendUInt32(CRC32.hash(footer[...]), to: &footer)
        output.append(contentsOf: footer)
        return output
    }

    private func makeHeader(version: UInt8) -> [UInt8] {
        var bytes = Array("REFT".utf8)
        bytes.append(version)
        bytes.append(contentsOf: [0, 0, 0])
        appendUInt64(updateIndex, to: &bytes)
        appendUInt64(updateIndex, to: &bytes)
        if version == 2 {
            bytes.append(contentsOf: objectFormat == .sha1
                ? Array("sha1".utf8)
                : Array("s256".utf8))
        }
        return bytes
    }

    private func makeLogBlock(_ updates: [ReftableUpdate]) throws -> [UInt8] {
        var body: [UInt8] = []
        var restarts: [Int] = []
        var prior: [UInt8] = []
        for (index, update) in updates.enumerated() {
            guard let metadata = update.reflog else { continue }
            var key = update.name.bytes + [0]
            appendUInt64(UInt64.max - updateIndex, to: &key)
            let restart = index.isMultiple(of: 16)
            let prefix = restart ? 0 : commonPrefix(prior, key)
            if restart { restarts.append(4 + body.count) }
            appendVarint(UInt64(prefix), to: &body)
            let suffix = key.dropFirst(prefix)
            appendVarint((UInt64(suffix.count) << 3) | 1, to: &body)
            body.append(contentsOf: suffix)
            let zero = [UInt8](repeating: 0, count: objectFormat.byteCount)
            let old: [UInt8]
            let new: [UInt8]
            if let objects = update.reflogObjects {
                guard objects.previous.algorithm == objectFormat,
                      objects.current.algorithm == objectFormat else {
                    throw ReftableError.hashMismatch
                }
                old = objects.previous.bytes
                new = objects.current.bytes
            } else {
                switch (update.expected, update.value) {
                case (.direct(let identifier), _):
                    old = identifier.bytes
                default:
                    old = zero
                }
                switch update.value {
                case .direct(let identifier, _):
                    new = identifier.bytes
                case .deletion, .symbolic:
                    new = zero
                }
            }
            body.append(contentsOf: old)
            body.append(contentsOf: new)
            let name = Array(metadata.signature.name.utf8)
            let email = Array(metadata.signature.email.utf8)
            let message = Array(
                (metadata.message.replacingOccurrences(of: "\n", with: " ") + "\n").utf8
            )
            appendVarint(UInt64(name.count), to: &body)
            body.append(contentsOf: name)
            appendVarint(UInt64(email.count), to: &body)
            body.append(contentsOf: email)
            guard metadata.signature.secondsSinceEpoch >= 0,
                  metadata.signature.timeZoneOffsetMinutes >= Int(Int16.min),
                  metadata.signature.timeZoneOffsetMinutes <= Int(Int16.max)
            else { throw ReftableError.invalidTable }
            appendVarint(
                UInt64(metadata.signature.secondsSinceEpoch),
                to: &body
            )
            appendUInt16(
                UInt16(bitPattern: Int16(metadata.signature.timeZoneOffsetMinutes)),
                to: &body
            )
            appendVarint(UInt64(message.count), to: &body)
            body.append(contentsOf: message)
            prior = key
        }
        for offset in restarts {
            try appendUInt24(offset, to: &body)
        }
        appendUInt16(UInt16(restarts.count), to: &body)
        let inflatedLength = 4 + body.count
        guard inflatedLength <= 0x00ff_ffff else {
            throw ReftableError.resourceLimitExceeded
        }
        var block: [UInt8] = [0x67, 0, 0, 0]
        setUInt24(inflatedLength, in: &block, at: 1)
        block.append(contentsOf: try Zlib.compress(body))
        return block
    }

    private func commonPrefix(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var value = value
        var encoded = [UInt8(value & 0x7f)]
        while value > 0x7f {
            value = (value >> 7) - 1
            encoded.append(UInt8(value & 0x7f) | 0x80)
        }
        bytes.append(contentsOf: encoded.reversed())
    }

    private func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private func appendUInt24(_ value: Int, to bytes: inout [UInt8]) throws {
        guard value >= 0, value <= 0x00ff_ffff else {
            throw ReftableError.resourceLimitExceeded
        }
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private func setUInt24(_ value: Int, in bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 16) & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        bytes[offset + 2] = UInt8(value & 0xff)
    }

    private func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
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
