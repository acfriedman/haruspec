import Foundation

/// The git questions a local check asks of one repository.
struct Git {
    /// The directory git commands run in; any directory inside the repository works.
    let directory: URL

    /// Returns the repository's top-level directory.
    ///
    /// - Returns: The standardized top level.
    /// - Throws: ``LocalCheckError/notARepository(_:)`` outside a git repository.
    func topLevel() throws -> URL {
        let result = try Shell.run(["git", "rev-parse", "--show-toplevel"], in: directory)
        guard result.status == 0 else {
            throw LocalCheckError.notARepository(directory.path)
        }
        return URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            .standardizedFileURL
    }

    /// Returns the full hash `revision` names.
    ///
    /// - Parameter revision: Any revision git accepts, e.g. `HEAD` or `main`.
    /// - Returns: The 40-character commit hash.
    /// - Throws: ``LocalCheckError/git(_:)`` when the revision does not resolve.
    func commit(_ revision: String) throws -> String {
        try output(
            ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
            explaining: "\(revision) is not a commit"
        )
    }

    /// Returns the best common ancestor of `HEAD` and `base`.
    ///
    /// - Parameter base: The branch the check compares against.
    /// - Returns: The merge base's full hash.
    /// - Throws: ``LocalCheckError/git(_:)`` when `base` does not resolve or shares no history with `HEAD`.
    func mergeBase(with base: String) throws -> String {
        try output(["merge-base", "HEAD", base], explaining: "no merge base between HEAD and \(base)")
    }

    /// Returns the checked-out branch's short name, or `nil` when `HEAD` is detached.
    ///
    /// - Returns: A name such as `feature/rewards`, or `nil`.
    /// - Throws: A launch error when git cannot start.
    func currentBranch() throws -> String? {
        let result = try Shell.run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !name.isEmpty ? name : nil
    }

    /// Whether the working tree differs from `HEAD`, counting untracked files that are not ignored
    /// and leaving out `.haruspec/`, whose contents never change behavior.
    ///
    /// - Returns: `true` when a check would measure uncommitted changes.
    /// - Throws: ``LocalCheckError/git(_:)`` when `git status` fails.
    func hasUncommittedChanges() throws -> Bool {
        try !output(["status", "--porcelain", "--"] + Self.outsideHaruspec, explaining: "git status failed").isEmpty
    }

    /// Returns the repo-relative paths that differ between `commit` and the working tree, untracked
    /// files included and `.haruspec/` left out.
    ///
    /// - Parameter commit: The commit to compare the working tree with.
    /// - Returns: The changed paths, sorted and without duplicates.
    /// - Throws: ``LocalCheckError/git(_:)`` when either listing fails.
    func changedFiles(since commit: String) throws -> [String] {
        let tracked = try output(
            ["diff", "--name-only", commit, "--"] + Self.outsideHaruspec,
            explaining: "git diff \(commit) failed"
        )
        let untracked = try output(
            ["ls-files", "--others", "--exclude-standard", "--"] + Self.outsideHaruspec,
            explaining: "git ls-files failed"
        )
        let paths = (tracked + "\n" + untracked).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return Array(Set(paths)).sorted()
    }

    /// Runs `git <arguments>` and returns its trimmed standard output.
    ///
    /// - Parameters:
    ///   - arguments: The git subcommand and its arguments.
    ///   - explaining: What a failure means, prefixed to git's own stderr.
    /// - Returns: Standard output without surrounding whitespace.
    /// - Throws: ``LocalCheckError/git(_:)`` on a nonzero exit.
    @discardableResult
    func output(_ arguments: [String], explaining: String) throws -> String {
        let result = try Shell.run(["git"] + arguments, in: directory)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalCheckError.git(detail.isEmpty ? explaining : "\(explaining): \(detail)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pathspec for everything in the repository except `.haruspec/`.
    static let outsideHaruspec = [":/", ":(top,exclude).haruspec"]
}
