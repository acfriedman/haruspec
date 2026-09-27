import Foundation

/// The repository as it was at the merge base, checked out as a git worktree under the cache so
/// the base side can be built and recorded without touching the developer's working tree.
struct BaseCheckout {
    /// The worktree's root: `<container>/<repository name>`.
    let root: URL

    /// Checks out `commit` into the cache's base worktree and mirrors the project's out-of-tree
    /// local packages beside it.
    ///
    /// - Parameters:
    ///   - commit: The full hash to check out.
    ///   - directory: The repository's `.haruspec/` layout.
    ///   - config: The repository's settings; names the projects whose local packages are mirrored.
    /// - Returns: The checkout, detached at `commit` with no untracked files.
    /// - Throws: ``LocalCheckError/git(_:)`` when the worktree cannot be created or moved, and
    ///   ``LocalCheckError/unmirrorablePackage(_:)`` when a local package lies outside the cache.
    static func prepare(commit: String, directory: HaruspecDirectory, config: LocalConfig) throws -> BaseCheckout {
        let git = Git(directory: directory.repositoryRoot)
        let container = directory.baseWorktreeContainer
        let root = container.appendingPathComponent(directory.repositoryRoot.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        // A worktree directory deleted by hand leaves a registration that blocks `worktree add`.
        try git.output(["worktree", "prune"], explaining: "git worktree prune failed")
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            let worktree = Git(directory: root)
            try worktree.output(
                ["checkout", "--quiet", "--force", "--detach", commit],
                explaining: "could not move the base worktree to \(commit)"
            )
            try worktree.output(["clean", "-fdxq"], explaining: "could not clean the base worktree")
        } else {
            try git.output(
                ["worktree", "add", "--quiet", "--detach", root.path, commit],
                explaining: "could not create the base worktree at \(root.path)"
            )
        }
        let checkout = BaseCheckout(root: root)
        try checkout.mirrorLocalPackages(from: directory.repositoryRoot, config: config, cache: directory.cache)
        return checkout
    }

    /// Links every out-of-tree local package the base's projects reference to the same package
    /// beside the real repository, so `../haruspec` resolves from the worktree as from the repository.
    ///
    /// - Parameters:
    ///   - repository: The real repository root the references are resolved against.
    ///   - config: The repository's settings.
    ///   - cache: The cache directory every link must stay inside.
    /// - Throws: ``LocalCheckError/unmirrorablePackage(_:)`` when a reference would place its link
    ///   outside `cache`, and a file-system error when a link cannot be written.
    func mirrorLocalPackages(from repository: URL, config: LocalConfig, cache: URL) throws {
        for project in projectFiles(config: config) {
            let relativeDirectory = project.deletingLastPathComponent().path
                .replacingOccurrences(of: root.path, with: "")
            let file = project.appendingPathComponent("project.pbxproj")
            let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for reference in Self.outOfTreePackageReferences(inProjectFile: contents) {
                // Resolved by text alone: Foundation's standardizing follows symlinks through `..`,
                // which would resolve an existing link to the package it points at.
                let link = Self.lexicallyResolved(root.path + relativeDirectory, reference)
                let target = Self.lexicallyResolved(repository.path + relativeDirectory, reference)
                guard link.path.hasPrefix(cache.standardizedFileURL.path + "/") else {
                    throw LocalCheckError.unmirrorablePackage(
                        "the local package \(reference) climbs out of the cache from the base worktree — "
                            + "reference it from inside the repository or by URL"
                    )
                }
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path {
                    continue
                }
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createParentDirectory(of: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            }
        }
    }

    /// Returns `relative` joined onto `directory` with `.` and `..` removed by text alone, never by
    /// asking the file system, so a symlink along the way is never followed.
    ///
    /// - Parameters:
    ///   - directory: An absolute directory path.
    ///   - relative: A path relative to `directory`, such as `../haruspec`.
    /// - Returns: The absolute file URL; `..` above the file-system root stays at the root.
    static func lexicallyResolved(_ directory: String, _ relative: String) -> URL {
        var components: [String] = []
        for component in (directory + "/" + relative).split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(String(component))
            }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }

    /// Returns the `relativePath` values of a project file that leave the project's directory — the
    /// `XCLocalSwiftPackageReference` entries that point outside the repository.
    ///
    /// - Parameter contents: The text of a `project.pbxproj`.
    /// - Returns: Each distinct reference beginning `../`, in first-seen order.
    static func outOfTreePackageReferences(inProjectFile contents: String) -> [String] {
        var seen: [String] = []
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("relativePath = "), trimmed.hasSuffix(";") else {
                continue
            }
            let value = trimmed.dropFirst("relativePath = ".count).dropLast()
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if value.hasPrefix("../"), !seen.contains(value) {
                seen.append(value)
            }
        }
        return seen
    }

    /// Returns the `.xcodeproj` bundles whose local package references are mirrored.
    ///
    /// - Parameter config: The repository's settings; its project, or its workspace's absence of one.
    /// - Returns: The configured project, or every project under the worktree for a workspace; empty
    ///   when a workspace's worktree holds none.
    private func projectFiles(config: LocalConfig) -> [URL] {
        if let project = config.project {
            return [root.appendingPathComponent(project)]
        }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var projects: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "xcodeproj" {
                projects.append(url)
            }
        }
        return projects
    }
}
