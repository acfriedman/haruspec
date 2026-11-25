import Foundation
import HaruspecTrace

// Resolving a traced declaration to the source an audit has to read. Filesystem knowledge lives here
// rather than in the recorded verdict: a verdict states what capture knew (a `#fileID`, a wrapped
// class name), and the tool holding a checkout turns that into paths. Same split as `haruspec report`.
//
// Two routes in, because the instrumentation knows two different things:
//   Swift  — the macro stamped a `#fileID`; match it against the tree by basename.
//   Obj-C  — only the wrapped class name survives, so find `@implementation <Name>`.
//
// The second is sound for a reason the label was not: an Obj-C class name is globally unique at link
// time, so the base implementation matches exactly once and every further hit is a category — which
// an audit wants too. Searching for the *label* ("Cart") could never work: a label is an alias two
// ports can share, and neither has to be named after it.

public struct SourceResolver: Sendable {
    /// Directories never worth walking: build products and VCS metadata, where a stale copy of a class
    /// would resolve to source nobody compiles.
    static let skippedDirectories: Set<String> = [
        ".git",
        ".build",
        ".swiftpm",
        "DerivedData",
        "build",
        "node_modules",
        "Carthage"
    ]

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Resolves each origin against one walk of the tree. Order is preserved, so a caller can zip the
    /// results back onto the verdict's origin list.
    ///
    /// - Parameter origins: The declarations to find, as the instrumentation registered them.
    /// - Returns: One resolution per origin, in the same order; empty when `origins` is.
    public func resolve(_ origins: some Sequence<TraceOrigin>) -> [SourceResolution] {
        let origins = Array(origins)
        guard !origins.isEmpty else { return [] }
        // Only symbols that actually need finding are searched for, so the content pass is skipped
        // entirely for a subject whose declarations all carry a `#fileID`.
        let wanted = Set(origins.filter { $0.source == nil }.compactMap(\.symbol).map(SourceIndex.declarationName))
        let index = SourceIndex(root: root, declarationsFor: wanted)
        return origins.map { SourceResolution(origin: $0, files: index.files(declaring: $0)) }
    }
}

/// One walk of the tree, answering both routes: file paths by basename (for a `#fileID`) and the
/// files declaring each wanted symbol (for a wrapped Obj-C class).
private struct SourceIndex {
    private var pathsByBasename: [String: [String]] = [:]
    private var pathsBySymbol: [String: Set<String>] = [:]

    init(root: URL, declarationsFor wanted: Set<String>) {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if SourceResolver.skippedDirectories.contains(name) {
                enumerator?.skipDescendants()
                continue
            }
            guard SourceIndex.sourceExtensions.contains(url.pathExtension) else { continue }
            let relative = SourceIndex.path(of: url, under: root)
            pathsByBasename[name, default: []].append(relative)
            if !wanted.isEmpty, let text = try? String(contentsOf: url, encoding: .utf8) {
                for symbol in SourceIndex.declaredSymbols(in: text, wanted: wanted) {
                    pathsBySymbol[symbol, default: []].insert(relative)
                }
            }
        }
    }

    private static func path(of url: URL, under root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base) else { return full }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static let sourceExtensions: Set<String> = ["swift", "m", "mm"]

    /// Returns the files declaring one origin.
    ///
    /// - Parameter origin: The declaration to find, as the instrumentation registered it.
    /// - Returns: The declaring files relative to the root, sorted; empty when none is found, which the
    ///   caller must treat as a blind spot, not a clean read (see ``SourceResolution``).
    func files(declaring origin: TraceOrigin) -> [String] {
        if let fileID = origin.source {
            return matches(forFileID: fileID)
        }
        guard let symbol = origin.symbol else { return [] }
        return pathsBySymbol[Self.declarationName(symbol)].map { $0.sorted() } ?? []
    }

    /// Returns the files a `#fileID` names. A `#fileID` is `Module/File.swift`, and the module is not
    /// necessarily a directory — so the file name decides and the module only breaks a tie.
    ///
    /// - Parameter fileID: The declaring file as a `#fileID` path (`"LegacyApp/SwiftCartActor.swift"`).
    /// - Returns: The matching files relative to the root, sorted; empty when no file has that name.
    ///
    /// An unbroken tie keeps *every* candidate: auditing a file too many is harmless, missing the real
    /// one is the failure this exists to avoid.
    private func matches(forFileID fileID: String) -> [String] {
        let basename = String(fileID.split(separator: "/").last ?? "")
        let candidates = pathsByBasename[basename] ?? []
        guard candidates.count > 1, let module = fileID.split(separator: "/").first else {
            return candidates.sorted()
        }
        let narrowed = candidates.filter { $0.split(separator: "/").contains(module) }
        return (narrowed.isEmpty ? candidates : narrowed).sorted()
    }

    /// Returns the name a type is declared under, given the name it runs under: a generic type runs as
    /// `Feed<HeldScheduler>` and is declared as `Feed<S: Scheduler>`, so the arguments are dropped.
    ///
    /// - Parameter symbol: The runtime type name an origin recorded.
    /// - Returns: `symbol` up to its first `<`.
    static func declarationName(_ symbol: String) -> String {
        String(symbol.prefix { $0 != "<" })
    }

    // MARK: - Declaration scanning

    /// Which of `wanted` this file declares. Line-oriented and anchored at the start of a declaration,
    /// so a mention inside a comment, a string, or an expression (`let type = MyClass.self`) doesn't
    /// count.
    ///
    /// - Parameters:
    ///   - text: The full source of one Swift or Objective-C file.
    ///   - wanted: The type names to look for; empty finds nothing.
    /// - Returns: The names in `wanted` that `text` declares as a Swift type or an Objective-C
    ///   `@implementation`, a category's included; empty when it declares none.
    static func declaredSymbols(in text: String, wanted: Set<String>) -> Set<String> {
        var found: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let name = objCImplementationName(in: trimmed) ?? swiftTypeName(in: trimmed),
                  wanted.contains(name)
            else { continue }
            found.insert(name)
        }
        return found
    }

    /// Returns the class an Obj-C `@implementation` line implements: `@implementation CartManager` and
    /// `@implementation CartManager (Promo)` alike. The category form matters most, since a category
    /// is behavior living in a file the class name doesn't name.
    ///
    /// - Parameter line: One source line, trimmed of surrounding whitespace.
    /// - Returns: The class name; `nil` when `line` is not an `@implementation`.
    static func objCImplementationName(in line: String) -> String? {
        let keyword = "@implementation"
        guard line.hasPrefix(keyword) else { return nil }
        return identifier(at: line.index(line.startIndex, offsetBy: keyword.count), in: line)
    }

    /// Returns the type a Swift type declaration line declares, allowing the modifiers and attributes
    /// that can precede one.
    ///
    /// - Parameter line: One source line, trimmed of surrounding whitespace.
    /// - Returns: The declared class, actor, struct, or enum name; `nil` when `line` is not such a
    ///   declaration.
    ///
    /// Only used when a forwarder wraps a Swift `@objc` class — unusual, but abstaining there would
    /// name a blind spot with the source sitting in the tree.
    static func swiftTypeName(in line: String) -> String? {
        var rest = Substring(line)
        while let token = nextToken(in: &rest) {
            if declarationKeywords.contains(token) {
                return identifier(at: rest.startIndex, in: line)
            }
            guard modifiers.contains(token) || token.hasPrefix("@") else { return nil }
        }
        return nil
    }

    /// Returns the next whitespace-delimited token, advancing `rest` past it. Attributes with
    /// arguments (`@objc(Cart)`) come back whole, which is all the modifier check needs.
    ///
    /// - Parameter rest: The unread remainder of the line, which receives what follows the token.
    /// - Returns: The token; `nil` when only whitespace remains.
    private static func nextToken(in rest: inout Substring) -> String? {
        rest = rest.drop { $0 == " " || $0 == "\t" }
        guard !rest.isEmpty else { return nil }
        let token = rest.prefix { $0 != " " && $0 != "\t" }
        rest = rest[token.endIndex...]
        return String(token)
    }

    /// Returns the identifier beginning at or after `start`, stopping at anything that can follow a
    /// type name (`:` inheritance, `<` generics, `(` a category, `{` the body).
    ///
    /// - Parameters:
    ///   - start: The position in `line` to read from.
    ///   - line: The source line being read.
    /// - Returns: The letters, digits, and underscores found there; `nil` when there are none.
    private static func identifier(at start: String.Index, in line: String) -> String? {
        let rest = line[start...].drop { $0 == " " || $0 == "\t" }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    private static let declarationKeywords: Set<String> = ["class", "actor", "struct", "enum"]
    private static let modifiers: Set<String> = [
        "public",
        "internal",
        "private",
        "fileprivate",
        "open",
        "package",
        "final",
        "indirect",
        "nonisolated",
        "dynamic",
        "static"
    ]
}
