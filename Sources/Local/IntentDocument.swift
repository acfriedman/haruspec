import Foundation
import HaruspecCore

// A branch's intent doc, `.haruspec/intent/<branch>.md`. Its declarations are ```haruspec-intent
// blocks — the same spelling a PR description carries — so pasting the file into a PR is exactly what
// the CI gate reads. Each spec lives in a section haruspec owns:
//
//   <!-- haruspec:begin cart -->
//   ### `cart`
//   ```haruspec-intent cart
//   Changes("LoyaltyPointsEarned", field: "points").increases()
//   ```
//   <!-- haruspec:evidence cart -->
//   …the last check's verdict for these declarations…
//   <!-- haruspec:end cart -->
//
// Anything outside the sections is the developer's prose and is never rewritten.

/// A branch's intent doc: per-spec declaration sections haruspec maintains, and whatever prose the
/// developer adds around them.
public struct IntentDocument: Equatable, Sendable {
    /// The whole file's text.
    public private(set) var text: String

    /// Creates a document from existing text.
    ///
    /// - Parameter text: The file's contents; empty for a document not yet written.
    public init(text: String) {
        self.text = text
    }

    /// Creates the text of a new document for `branch`.
    ///
    /// - Parameter branch: The branch the declarations belong to, shown in the title.
    /// - Returns: A title and a sentence saying what the file is.
    public static func empty(branch: String) -> IntentDocument {
        IntentDocument(text: """
        # Declared intent — `\(branch)`

        The behavior changes this branch means to make, one `\(IntentGrammar.fenceLabel)` block per \
        spec, each with the evidence from the last `haruspec check`. Paste this file into the PR \
        description to declare the same intent to the CI gate.

        """)
    }

    /// Reads the document at `url` (or starts one for `branch`), applies `edit`, and writes it back.
    ///
    /// - Parameters:
    ///   - url: The intent doc's path; its directory is created when missing.
    ///   - branch: The branch named in a new document's title.
    ///   - edit: The change to make; a throw leaves the file untouched.
    /// - Returns: The document as written.
    /// - Throws: Whatever `edit` throws, and a file-system error when the file cannot be written.
    @discardableResult
    public static func update(
        at url: URL,
        branch: String,
        _ edit: (inout IntentDocument) throws -> Void
    ) throws -> IntentDocument {
        var document = (try? String(contentsOf: url, encoding: .utf8)).map(IntentDocument.init(text:))
            ?? .empty(branch: branch)
        try edit(&document)
        try FileManager.default.createParentDirectory(of: url)
        try Data(document.text.utf8).write(to: url)
        return document
    }

    /// The declarations the document holds, keyed by spec — the same reading the CI gate makes of a
    /// PR description.
    ///
    /// - Returns: Each declared spec's intent; empty when the document declares nothing.
    /// - Throws: `IntentGrammarError` when a block does not parse or a spec is declared twice.
    public func intents() throws -> [String: Intent] {
        try IntentGrammar.intents(inBody: text)
    }

    /// Returns the declaration lines of `spec`'s section, in file order.
    ///
    /// - Parameter spec: A spec name.
    /// - Returns: The lines inside the section's fence; empty when the document has no section for it.
    public func declarations(for spec: String) -> [String] {
        guard let range = section(for: spec) else {
            return []
        }
        let lines = String(text[range]).components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.hasPrefix("```\(IntentGrammar.fenceLabel)") }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.hasPrefix("```") }) else {
            return []
        }
        return lines[(open + 1) ..< close].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Adds `declarations` to `spec`'s section, or replaces its lines when `replacing` is set, and
    /// resets the section's evidence until the next check.
    ///
    /// - Parameters:
    ///   - declarations: DSL lines such as `Changes("Receipt", field: "total").increases()`.
    ///   - spec: The spec they declare intent for.
    ///   - replacing: Whether the given lines replace the section's lines instead of joining them.
    /// - Throws: ``LocalCheckError/intentDocument(_:)`` when `spec` is declared outside a haruspec
    ///   section or the result would be empty, and `IntentGrammarError` when a line does not parse.
    public mutating func save(_ declarations: [String], for spec: String, replacing: Bool) throws {
        let existing = self.declarations(for: spec)
        let lines = replacing ? declarations : existing + declarations.filter { !existing.contains($0) }
        guard !lines.isEmpty else {
            throw LocalCheckError.intentDocument("no declarations to save for \(spec) — to drop the spec, remove it")
        }
        try Self.validate(lines, for: spec)
        try refuseUnmanagedBlock(for: spec)
        let body = Self.section(spec: spec, declarations: lines, evidence: Self.uncheckedEvidence)
        if let range = section(for: spec) {
            text.replaceSubrange(range, with: body)
        } else {
            while !text.isEmpty, !text.hasSuffix("\n\n") {
                text += "\n"
            }
            text += body + "\n"
        }
    }

    /// Removes `spec`'s section.
    ///
    /// - Parameter spec: The spec whose declarations to drop.
    /// - Throws: ``LocalCheckError/intentDocument(_:)`` when the document has no section for `spec`.
    public mutating func remove(_ spec: String) throws {
        guard let range = section(for: spec) else {
            throw LocalCheckError.intentDocument("the intent doc has no section for \(spec)")
        }
        var end = range.upperBound
        while end < text.endIndex, text[end] == "\n" {
            end = text.index(after: end)
        }
        text.removeSubrange(range.lowerBound ..< end)
    }

    /// Replaces the evidence under `spec`'s declarations with `evidence`.
    ///
    /// - Parameters:
    ///   - evidence: Markdown with no `haruspec-intent` fence, typically a check's verdict record.
    ///   - spec: The spec the evidence is for; a spec with no section is left alone.
    public mutating func setEvidence(_ evidence: String, for spec: String) {
        guard let range = section(for: spec) else {
            return
        }
        let body = Self.section(spec: spec, declarations: declarations(for: spec), evidence: evidence)
        text.replaceSubrange(range, with: body)
    }

    /// The specs with a haruspec section, in file order.
    public var sectionSpecs: [String] {
        text.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(Self.beginPrefix), trimmed.hasSuffix(" -->") else {
                return nil
            }
            return String(trimmed.dropFirst(Self.beginPrefix.count).dropLast(" -->".count))
        }
    }

    // MARK: - Sections

    private static let beginPrefix = "<!-- haruspec:begin "
    private static let uncheckedEvidence = "_Not yet checked with these declarations — run `haruspec check`._"

    private static func section(spec: String, declarations: [String], evidence: String) -> String {
        """
        \(beginPrefix)\(spec) -->
        ### `\(spec)`

        ```\(IntentGrammar.fenceLabel) \(spec)
        \(declarations.joined(separator: "\n"))
        ```

        <!-- haruspec:evidence \(spec) -->
        \(evidence)
        <!-- haruspec:end \(spec) -->
        """
    }

    private func refuseUnmanagedBlock(for spec: String) throws {
        var outside = text
        if let range = section(for: spec) {
            outside.removeSubrange(range)
        }
        if (try? IntentGrammar.intents(inBody: outside))?[spec] != nil {
            throw LocalCheckError.intentDocument(
                "\(spec) is already declared in a block haruspec does not manage — edit that block by hand, "
                    + "or delete it and save again"
            )
        }
    }

    /// Returns the range from `spec`'s begin marker through its end marker.
    ///
    /// - Parameter spec: A spec name.
    /// - Returns: The section's range, or `nil` when the document has no complete section for `spec`.
    private func section(for spec: String) -> Range<String.Index>? {
        guard let begin = text.range(of: "\(Self.beginPrefix)\(spec) -->"),
              let end = text.range(of: "<!-- haruspec:end \(spec) -->", range: begin.upperBound ..< text.endIndex)
        else {
            return nil
        }
        return begin.lowerBound ..< end.upperBound
    }

    private static func validate(_ lines: [String], for spec: String) throws {
        let block = "```\(IntentGrammar.fenceLabel) \(spec)\n" + lines.joined(separator: "\n") + "\n```"
        _ = try IntentGrammar.intents(inBody: block)
    }
}
