import Foundation

// The `.haruspec/` directory at a repository's root:
//
//   .haruspec/
//     config.json            committed — the opt-in and the test-run settings
//     intent/<branch>.md     the team decides whether to commit these
//     cache/                 machine output; ignores itself through its own .gitignore
//       plans/<base-sha>/schema-<n>/<spec>.plan.json.gz
//       worktrees/base/<repo>/
//       derived/{base,head}/
//       runs/<run-id>/ · runs/latest

/// The paths under one repository's `.haruspec/` directory.
public struct HaruspecDirectory: Sendable {
    /// The repository's root (the git top level).
    public let repositoryRoot: URL

    /// Creates the layout for the repository rooted at `repositoryRoot`.
    ///
    /// - Parameter repositoryRoot: The git top level; nothing is created on disk.
    public init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot.standardizedFileURL
    }

    /// The `.haruspec/` directory itself.
    public var root: URL {
        repositoryRoot.appendingPathComponent(".haruspec", isDirectory: true)
    }

    /// The configuration file.
    public var config: URL {
        root.appendingPathComponent(LocalConfig.fileName)
    }

    /// The directory of per-branch intent docs.
    public var intent: URL {
        root.appendingPathComponent("intent", isDirectory: true)
    }

    /// The machine-output directory, never committed.
    public var cache: URL {
        root.appendingPathComponent("cache", isDirectory: true)
    }

    /// Returns the intent doc for `branch`; a branch name with slashes nests.
    ///
    /// - Parameter branch: A branch name such as `feature/rewards`.
    /// - Returns: The doc's path, whether or not it exists.
    public func intentDocument(branch: String) -> URL {
        intent.appendingPathComponent(branch + ".md")
    }

    /// Returns the directory holding plans recorded at `baseSHA` under the plan schema `schema`.
    ///
    /// - Parameters:
    ///   - baseSHA: The full commit hash the plans were recorded at.
    ///   - schema: The plan schema version the recording engine wrote.
    /// - Returns: The directory, whether or not it exists.
    public func plans(baseSHA: String, schema: Int) -> URL {
        cache.appendingPathComponent("plans/\(baseSHA)/schema-\(schema)", isDirectory: true)
    }

    /// The directory the base checkout's worktree lives under, one level above the worktree so
    /// out-of-tree local packages can be mirrored beside it.
    public var baseWorktreeContainer: URL {
        cache.appendingPathComponent("worktrees/base", isDirectory: true)
    }

    /// Returns the derived-data directory for one side of the comparison.
    ///
    /// - Parameter side: `"base"` or `"head"`.
    /// - Returns: The directory, whether or not it exists.
    public func derivedData(_ side: String) -> URL {
        cache.appendingPathComponent("derived/\(side)", isDirectory: true)
    }

    /// The directory of per-run outputs.
    public var runs: URL {
        cache.appendingPathComponent("runs", isDirectory: true)
    }

    /// The file naming the most recent run's id.
    public var latestRun: URL {
        runs.appendingPathComponent("latest")
    }

    /// Creates the cache directory and its `.gitignore`, so machine output is never committed
    /// whatever the repository's own ignore rules say.
    ///
    /// - Throws: A file-system error when the directory or file cannot be written.
    public func prepareCache() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let ignore = cache.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Data("# Written by haruspec: everything here is machine output.\n*\n".utf8).write(to: ignore)
        }
    }
}
