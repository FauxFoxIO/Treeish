import Foundation
import TreeishCore
import TreeishFileSystem

public enum Treeish {
    public static func discover(
        in root: TreeishRoot,
        from path: GitPath = .root
    ) async throws -> RepositoryLocation {
        var components = try path.components
        while true {
            if try root.directory.exists(components + [".git"]) {
                let gitURL = try root.directory.url(
                    for: components + [".git"],
                    followFinalSymlink: false
                )
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(
                    atPath: gitURL.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue {
                    return try normalLocation(
                        worktree: components,
                        gitDirectory: components + [".git"]
                    )
                }
                let data = try root.directory.read(
                    components + [".git"],
                    limit: 64 * 1024
                )
                guard let line = String(bytes: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      line.hasPrefix("gitdir:")
                else {
                    throw TreeishError.repositoryNotFound
                }
                let value = line.dropFirst("gitdir:".count)
                    .trimmingCharacters(in: .whitespaces)
                let worktreeURL = try root.directory.url(for: components)
                let gitDirectoryURL = URL(
                    fileURLWithPath: value,
                    relativeTo: worktreeURL
                ).standardizedFileURL
                let gitComponents = try root.directory.relativeComponents(
                    for: gitDirectoryURL
                )
                return try linkedLocation(
                    root: root,
                    worktree: components,
                    gitDirectory: gitComponents
                )
            }

            if try root.directory.exists(components + ["HEAD"]),
               try root.directory.exists(components + ["objects"]) {
                let path = try gitPath(components)
                return RepositoryLocation(
                    worktreePath: nil,
                    gitDirectoryPath: path,
                    commonDirectoryPath: path,
                    objectDirectoryPath: try gitPath(components + ["objects"]),
                    isBare: true
                )
            }

            guard !components.isEmpty else {
                throw TreeishError.repositoryNotFound
            }
            components.removeLast()
        }
    }

    public static func open(
        _ location: RepositoryLocation,
        roots: [TreeishRoot],
        options: RepositoryOpenOptions = .init()
    ) async throws -> Repository {
        guard let root = roots.first else {
            throw TreeishError.repositoryNotFound
        }
        return try Repository(
            root: root,
            location: location,
            options: options
        )
    }

    public static func initialize(
        in root: TreeishRoot,
        at path: GitPath = .root,
        options: RepositoryInitialization = .init()
    ) async throws -> Repository {
        guard options.objectFormat == .sha1 else {
            throw TreeishError.unsupportedRepositoryFormat(
                "SHA-256 mutation is not implemented"
            )
        }
        _ = try RefName("refs/heads/\(options.initialBranch)")
        let base = try path.components
        try root.directory.createDirectory(base)
        let git = options.bare ? base : base + [".git"]
        for directory in [
            git,
            git + ["branches"],
            git + ["hooks"],
            git + ["info"],
            git + ["objects"],
            git + ["objects", "info"],
            git + ["objects", "pack"],
            git + ["refs"],
            git + ["refs", "heads"],
            git + ["refs", "tags"],
        ] {
            try root.directory.createDirectory(directory)
        }
        try root.directory.writeAtomically(
            Array("ref: refs/heads/\(options.initialBranch)\n".utf8),
            to: git + ["HEAD"]
        )
        let bareValue = options.bare ? "true" : "false"
        try root.directory.writeAtomically(
            Array("""
            [core]
            \trepositoryformatversion = 0
            \tfilemode = true
            \tbare = \(bareValue)
            \tlogallrefupdates = true

            """.utf8),
            to: git + ["config"]
        )
        try root.directory.writeAtomically(
            Array("Unnamed repository; edit this file 'description' to name the repository.\n".utf8),
            to: git + ["description"]
        )
        let location: RepositoryLocation
        if options.bare {
            location = RepositoryLocation(
                worktreePath: nil,
                gitDirectoryPath: path,
                commonDirectoryPath: path,
                objectDirectoryPath: try gitPath(git + ["objects"]),
                isBare: true
            )
        } else {
            location = try normalLocation(worktree: base, gitDirectory: git)
        }
        return try Repository(
            root: root,
            location: location,
            options: .init()
        )
    }

    public static func clone(
        _ request: CloneRequest,
        in root: TreeishRoot,
        services: RepositoryServices = .init()
    ) async throws -> Repository {
        let destinationComponents = try request.destination.components
        guard !destinationComponents.isEmpty,
              !(try root.directory.exists(destinationComponents)) else {
            throw TreeishError.worktreeCollision(request.destination)
        }
        let requestedBranchName = request.branch.map {
            String($0.description.dropFirst("refs/heads/".count))
        }
        let repository = try await initialize(
            in: root,
            at: request.destination,
            options: RepositoryInitialization(
                initialBranch: requestedBranchName ?? "main"
            )
        )
        let fetched = try await repository.fetch(
            try FetchRequest(
                remote: request.remote,
                remoteName: request.remoteName,
                refNames: request.branch.map { [$0] } ?? []
            ),
            services: services
        ).value()
        let selectedRemote: RefUpdateResult
        if let requested = request.branch {
            let tail = requested.description.dropFirst("refs/heads/".count)
            let expected = "refs/remotes/\(request.remoteName)/\(tail)"
            guard let value = fetched.updatedReferences.first(where: {
                $0.name.description == expected
            }) else { throw TreeishError.referenceNotFound }
            selectedRemote = value
        } else if let remoteHead = fetched.remoteHead,
                  let value = fetched.updatedReferences.first(where: {
                      $0.name == remoteHead
                  }) {
            selectedRemote = value
        } else if let value = fetched.updatedReferences.first {
            selectedRemote = value
        } else {
            throw TreeishError.referenceNotFound
        }
        let branchName = String(selectedRemote.name.description.split(separator: "/").last ?? "main")
        let localBranch = try RefName("refs/heads/\(branchName)")
        _ = try await repository.checkout(
            CheckoutRequest(commit: selectedRemote.current, reference: localBranch)
        ).value()
        let configPath = destinationComponents + [".git", "config"]
        let existing = try root.directory.read(configPath, limit: 16 * 1024 * 1024)
        let remoteConfiguration = """
        [remote "\(request.remoteName)"]
        \turl = \(request.remote.description)
        \tfetch = +refs/heads/*:refs/remotes/\(request.remoteName)/*
        [branch "\(branchName)"]
        \tremote = \(request.remoteName)
        \tmerge = refs/heads/\(branchName)

        """
        try root.directory.writeAtomically(
            existing + Array(remoteConfiguration.utf8),
            to: configPath
        )
        return repository
    }

    private static func normalLocation(
        worktree: [String],
        gitDirectory: [String]
    ) throws -> RepositoryLocation {
        RepositoryLocation(
            worktreePath: try gitPath(worktree),
            gitDirectoryPath: try gitPath(gitDirectory),
            commonDirectoryPath: try gitPath(gitDirectory),
            objectDirectoryPath: try gitPath(gitDirectory + ["objects"]),
            isBare: false
        )
    }

    private static func linkedLocation(
        root: TreeishRoot,
        worktree: [String],
        gitDirectory: [String]
    ) throws -> RepositoryLocation {
        let commonData = try root.directory.read(
            gitDirectory + ["commondir"],
            limit: 64 * 1024
        )
        guard let commonText = String(bytes: commonData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw TreeishError.repositoryNotFound
        }
        let gitURL = try root.directory.url(for: gitDirectory)
        let commonURL = URL(
            fileURLWithPath: commonText,
            relativeTo: gitURL
        ).standardizedFileURL
        let common = try root.directory.relativeComponents(for: commonURL)
        return RepositoryLocation(
            worktreePath: try gitPath(worktree),
            gitDirectoryPath: try gitPath(gitDirectory),
            commonDirectoryPath: try gitPath(common),
            objectDirectoryPath: try gitPath(common + ["objects"]),
            isBare: false
        )
    }

    private static func gitPath(_ components: [String]) throws -> GitPath {
        try GitPath(components.joined(separator: "/"))
    }
}
