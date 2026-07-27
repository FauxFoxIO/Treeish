import Foundation
import TreeishCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum RootDirectoryError: Error, Sendable, Equatable {
    case notDirectory
    case pathEscapesRoot
    case symbolicLinkNotAllowed
    case invalidRelativePath
    case atomicReplacementFailed
    case notFound
}

public struct RootDirectoryIdentity: Sendable, Hashable, Codable {
    public let canonicalPath: String

    public init(canonicalPath: String) {
        self.canonicalPath = canonicalPath
    }
}

public struct RootDirectory: Sendable {
    public let identity: RootDirectoryIdentity
    private let canonicalURL: URL
    private let descriptor: RootDescriptor

    public init(url: URL) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonical.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw RootDirectoryError.notDirectory
        }
        let fileDescriptor = open(canonical.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fileDescriptor >= 0 else { throw RootDirectoryError.notDirectory }
        canonicalURL = canonical
        descriptor = RootDescriptor(fileDescriptor)
        identity = RootDirectoryIdentity(canonicalPath: canonical.path)
    }

    public func url(for components: [String], followFinalSymlink: Bool = true) throws -> URL {
        guard components.allSatisfy(isValidComponent) else {
            throw RootDirectoryError.invalidRelativePath
        }
        let candidate = components.reduce(canonicalURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }.standardizedFileURL
        let verified = followFinalSymlink
            ? candidate.resolvingSymlinksInPath()
            : candidate.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(candidate.lastPathComponent)
        try requireContained(verified)
        return verified
    }

    public func read(_ components: [String], limit: Int) throws -> [UInt8] {
        guard limit >= 0, let name = components.last else {
            throw RootDirectoryError.invalidRelativePath
        }
        let parent = try openDirectory(Array(components.dropLast()))
        defer { if parent.owned { close(parent.fd) } }
        let fd = name.withCString {
            openat(parent.fd, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            if errno == ENOENT { throw RootDirectoryError.notFound }
            throw RootDirectoryError.symbolicLinkNotAllowed
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0,
              info.st_size <= limit else {
            throw ZlibError.resourceLimitExceeded
        }
        var output: [UInt8] = []
        output.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(1, limit)))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            guard count >= 0 else { throw RootDirectoryError.invalidRelativePath }
            if count == 0 { break }
            guard output.count <= limit - count else {
                throw ZlibError.resourceLimitExceeded
            }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }

    public func createDirectory(_ components: [String]) throws {
        guard components.allSatisfy(isValidComponent) else {
            throw RootDirectoryError.invalidRelativePath
        }
        var current = descriptor.fd
        var ownsCurrent = false
        defer { if ownsCurrent { close(current) } }
        for component in components {
            let created = component.withCString { mkdirat(current, $0, 0o755) }
            if created != 0, errno != EEXIST {
                throw RootDirectoryError.invalidRelativePath
            }
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { throw RootDirectoryError.symbolicLinkNotAllowed }
            if ownsCurrent { close(current) }
            current = next
            ownsCurrent = true
        }
    }

    public func writeAtomically(
        _ bytes: [UInt8],
        to components: [String],
        createDirectories: Bool = true
    ) throws {
        guard let name = components.last, components.allSatisfy(isValidComponent) else {
            throw RootDirectoryError.invalidRelativePath
        }
        let parentComponents = Array(components.dropLast())
        if createDirectories {
            try createDirectory(parentComponents)
        }
        let parent = try openDirectory(parentComponents)
        defer { if parent.owned { close(parent.fd) } }
        let temporary = ".treeish-\(UUID().uuidString.lowercased()).lock"
        let temporaryFD = temporary.withCString {
            openat(parent.fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        }
        guard temporaryFD >= 0 else { throw RootDirectoryError.atomicReplacementFailed }
        var temporaryIsOpen = true
        do {
            var written = 0
            while written < bytes.count {
                let count = bytes.withUnsafeBytes { raw in
                    Darwin.write(
                        temporaryFD,
                        raw.baseAddress?.advanced(by: written),
                        bytes.count - written
                    )
                }
                guard count > 0 else { throw RootDirectoryError.atomicReplacementFailed }
                written += count
            }
            guard fsync(temporaryFD) == 0 else {
                throw RootDirectoryError.atomicReplacementFailed
            }
            close(temporaryFD)
            temporaryIsOpen = false
            let renamed = temporary.withCString { temporaryName in
                name.withCString { destinationName in
                    renameat(parent.fd, temporaryName, parent.fd, destinationName)
                }
            }
            guard renamed == 0, fsync(parent.fd) == 0 else {
                throw RootDirectoryError.atomicReplacementFailed
            }
        } catch {
            if temporaryIsOpen { close(temporaryFD) }
            _ = temporary.withCString { unlinkat(parent.fd, $0, 0) }
            throw error
        }
    }

    public func compareAndSwap(
        _ bytes: [UInt8],
        to components: [String],
        expected: [UInt8]?,
        requireMissing: Bool = false
    ) throws -> Bool {
        guard let name = components.last, components.allSatisfy(isValidComponent) else {
            throw RootDirectoryError.invalidRelativePath
        }
        let parentComponents = Array(components.dropLast())
        try createDirectory(parentComponents)
        let parent = try openDirectory(parentComponents)
        defer { if parent.owned { close(parent.fd) } }
        let lockName = name + ".lock"
        let lockFD = lockName.withCString {
            openat(parent.fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        }
        guard lockFD >= 0 else { throw RootDirectoryError.atomicReplacementFailed }
        var lockIsOpen = true
        do {
            if requireMissing {
                var info = stat()
                let exists = name.withCString {
                    fstatat(parent.fd, $0, &info, AT_SYMLINK_NOFOLLOW) == 0
                }
                guard !exists else {
                    close(lockFD)
                    lockIsOpen = false
                    _ = lockName.withCString { unlinkat(parent.fd, $0, 0) }
                    return false
                }
            }
            if let expected {
                let current: [UInt8]
                do {
                    current = try read(components, limit: max(4_096, expected.count + 1))
                } catch RootDirectoryError.notFound {
                    close(lockFD)
                    lockIsOpen = false
                    _ = lockName.withCString { unlinkat(parent.fd, $0, 0) }
                    return false
                }
                guard current == expected else {
                    close(lockFD)
                    lockIsOpen = false
                    _ = lockName.withCString { unlinkat(parent.fd, $0, 0) }
                    return false
                }
            }
            try writeAll(bytes, to: lockFD)
            guard fsync(lockFD) == 0 else {
                throw RootDirectoryError.atomicReplacementFailed
            }
            close(lockFD)
            lockIsOpen = false
            let renamed = lockName.withCString { source in
                name.withCString { destination in
                    renameat(parent.fd, source, parent.fd, destination)
                }
            }
            guard renamed == 0, fsync(parent.fd) == 0 else {
                throw RootDirectoryError.atomicReplacementFailed
            }
            return true
        } catch {
            if lockIsOpen { close(lockFD) }
            _ = lockName.withCString { unlinkat(parent.fd, $0, 0) }
            throw error
        }
    }

    public func appendAtomically(
        _ bytes: [UInt8],
        to components: [String],
        maximumExistingBytes: Int = 64 * 1024 * 1024
    ) throws {
        let existing: [UInt8]
        let wasMissing: Bool
        do {
            existing = try read(components, limit: maximumExistingBytes)
            wasMissing = false
        } catch RootDirectoryError.notFound {
            existing = []
            wasMissing = true
        }
        guard existing.count <= maximumExistingBytes - bytes.count else {
            throw ZlibError.resourceLimitExceeded
        }
        guard try compareAndSwap(
            existing + bytes,
            to: components,
            expected: wasMissing ? nil : existing,
            requireMissing: wasMissing
        ) else {
            throw RootDirectoryError.atomicReplacementFailed
        }
    }

    public func moveAtomically(
        from source: [String],
        to destination: [String]
    ) throws {
        guard let sourceName = source.last,
              let destinationName = destination.last,
              source.allSatisfy(isValidComponent),
              destination.allSatisfy(isValidComponent) else {
            throw RootDirectoryError.invalidRelativePath
        }
        let sourceParent = try openDirectory(Array(source.dropLast()))
        defer { if sourceParent.owned { close(sourceParent.fd) } }
        let destinationComponents = Array(destination.dropLast())
        try createDirectory(destinationComponents)
        let destinationParent = try openDirectory(destinationComponents)
        defer { if destinationParent.owned { close(destinationParent.fd) } }
        if try exists(destination) {
            _ = sourceName.withCString { unlinkat(sourceParent.fd, $0, 0) }
            return
        }
        let moved = sourceName.withCString { sourceValue in
            destinationName.withCString { destinationValue in
                renameat(
                    sourceParent.fd,
                    sourceValue,
                    destinationParent.fd,
                    destinationValue
                )
            }
        }
        guard moved == 0,
              fsync(sourceParent.fd) == 0,
              (sourceParent.fd == destinationParent.fd || fsync(destinationParent.fd) == 0)
        else { throw RootDirectoryError.atomicReplacementFailed }
    }

    public func removeAtomically(
        _ components: [String],
        expected: [UInt8]? = nil
    ) throws -> Bool {
        guard let name = components.last, components.allSatisfy(isValidComponent) else {
            throw RootDirectoryError.invalidRelativePath
        }
        let parent = try openDirectory(Array(components.dropLast()))
        defer { if parent.owned { close(parent.fd) } }
        let lockName = name + ".lock"
        let lockFD = lockName.withCString {
            openat(parent.fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        }
        guard lockFD >= 0 else { throw RootDirectoryError.atomicReplacementFailed }
        close(lockFD)
        defer { _ = lockName.withCString { unlinkat(parent.fd, $0, 0) } }
        if let expected {
            let current: [UInt8]
            do { current = try read(components, limit: max(4096, expected.count + 1)) }
            catch RootDirectoryError.notFound { return false }
            guard current == expected else { return false }
        }
        let removed = name.withCString { unlinkat(parent.fd, $0, 0) }
        if removed != 0, errno == ENOENT { return false }
        guard removed == 0, fsync(parent.fd) == 0 else {
            throw RootDirectoryError.atomicReplacementFailed
        }
        return true
    }

    public func exists(_ components: [String]) throws -> Bool {
        guard let name = components.last else { return true }
        let parent: (fd: Int32, owned: Bool)
        do {
            parent = try openDirectory(Array(components.dropLast()))
        } catch RootDirectoryError.notFound {
            return false
        }
        defer { if parent.owned { close(parent.fd) } }
        var info = stat()
        let result = name.withCString {
            fstatat(parent.fd, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw RootDirectoryError.invalidRelativePath
    }

    public func childDirectory(_ components: [String]) throws -> RootDirectory {
        try RootDirectory(url: url(for: components))
    }

    public func relativeComponents(for absoluteURL: URL) throws -> [String] {
        // URL.standardizedFileURL may resolve a dangling final symlink on
        // Darwin. NSString path standardization removes dot components while
        // preserving the directory entry itself.
        let lexical = URL(
            fileURLWithPath: (absoluteURL.path as NSString).standardizingPath
        )

        // The directory walk already prevents symlink traversal for parents. Do
        // not resolve the final component here: a Git symlink is an entry whose
        // path is the link itself, not the path of its target.
        let parent = lexical.deletingLastPathComponent().resolvingSymlinksInPath()
        try requireContained(parent)
        let verified = parent.appendingPathComponent(lexical.lastPathComponent)
        let rootComponents = canonicalURL.pathComponents
        return Array(verified.pathComponents.dropFirst(rootComponents.count))
    }

    private func requireContained(_ url: URL) throws {
        let candidateComponents = (url.path as NSString).standardizingPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let normalizedRootComponents = canonicalURL.pathComponents.filter { $0 != "/" }
        guard candidateComponents.starts(with: normalizedRootComponents) else {
            throw RootDirectoryError.pathEscapesRoot
        }
    }

    private func isValidComponent(_ component: String) -> Bool {
        !component.isEmpty &&
        component != "." &&
        component != ".." &&
        !component.contains("/") &&
        !component.utf8.contains(0)
    }

    private func openDirectory(_ components: [String]) throws -> (fd: Int32, owned: Bool) {
        guard components.allSatisfy(isValidComponent) else {
            throw RootDirectoryError.invalidRelativePath
        }
        if components.isEmpty { return (descriptor.fd, false) }
        var current = descriptor.fd
        var ownsCurrent = false
        do {
            for component in components {
                let next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else {
                    if errno == ENOENT { throw RootDirectoryError.notFound }
                    throw RootDirectoryError.symbolicLinkNotAllowed
                }
                if ownsCurrent { close(current) }
                current = next
                ownsCurrent = true
            }
            return (current, ownsCurrent)
        } catch {
            if ownsCurrent { close(current) }
            throw error
        }
    }


    private func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.write(
                    fd,
                    raw.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
            }
            guard count > 0 else { throw RootDirectoryError.atomicReplacementFailed }
            written += count
        }
    }
}

private final class RootDescriptor: @unchecked Sendable {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { close(fd) }
}
