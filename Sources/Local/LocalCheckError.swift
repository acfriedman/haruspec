import Foundation

/// Every way a local check or an intent save refuses, each message naming the fix.
public enum LocalCheckError: Error, Equatable, CustomStringConvertible {
    /// No `.haruspec/config.json` at the given path.
    case missingConfig(String)
    /// The configuration exists but does not decode or validate.
    case invalidConfig(String)
    /// A `git` command failed; the associated text is the command and its stderr.
    case git(String)
    /// The working directory is not inside a git repository.
    case notARepository(String)
    /// HEAD is detached, so there is no branch to key the intent doc by.
    case detachedHead
    /// No spec was declared in the test target, or a requested spec is not declared.
    case noSpecs(String)
    /// An out-of-tree local package cannot be mirrored beside the base checkout.
    case unmirrorablePackage(String)
    /// The intent doc could not be read or edited as asked.
    case intentDocument(String)

    public var description: String {
        switch self {
        case let .missingConfig(path):
            "no \(path) — haruspec check is opt-in; create it to opt this repository in:\n\n"
                + LocalConfig.example
        case let .invalidConfig(reason):
            ".haruspec/\(LocalConfig.fileName) is invalid: \(reason)"
        case let .git(detail):
            "git failed: \(detail)"
        case let .notARepository(path):
            "\(path) is not inside a git repository — haruspec check compares git revisions"
        case .detachedHead:
            "HEAD is detached, so there is no branch to key the intent doc by — check out a branch, "
                + "or pass --intent <file>"
        case let .noSpecs(reason):
            reason
        case let .unmirrorablePackage(reason):
            reason
        case let .intentDocument(reason):
            reason
        }
    }
}
