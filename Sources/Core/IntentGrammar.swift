import Foundation

// The text form of the intent DSL — how a PR declares intent without committing a file. A PR
// description carries one fenced block per spec:
//
//     ```haruspec-intent search.combine
//     Changes("Search.query")
//     Moves("Searcher.products", from: .main, to: .ambient)
//     ```
//
// and CI resolves each block to the `Intent` the replay applies. The grammar IS the DSL's
// spellings — one vocabulary, whether declared in code at a check site or in text on a PR — and
// every engine rendering of a declaration (unobserved-intent warnings, suggested declarations on a
// red verdict) is a line this parser accepts back verbatim.
//
// Parsing is fail-fast and teaching: an unparseable line names itself, what was expected, and a
// valid example, because the error message is the interface that guides an author to the grammar.

/// Parses the intent DSL's text form: whole PR bodies into per-spec `Intent`s, or bare declaration
/// lines into one.
public enum IntentGrammar {
    /// The info string that marks a fenced code block as an intent declaration.
    public static let fenceLabel = "haruspec-intent"

    /// Extracts every ` ```haruspec-intent <spec>` fenced block from a PR body and parses each into
    /// the `Intent` declared for that spec. A body with no intent blocks is parity mode: `[:]`.
    ///
    /// - Precondition (thrown, not trapped): every block names a spec, parses, and no spec appears
    ///   in two blocks — a second block would silently widen the first.
    public static func intents(inBody body: String) throws -> [String: Intent] {
        var intents: [String: Intent] = [:]
        var currentSpec: String?
        var currentLines: [String] = []
        var blockStart = 0
        var insidePlainFence = false

        for (offset, rawLine) in body.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A body can quote fenced blocks that are not declarations (a diff, a log, the sticky
            // comment itself); a literal ```haruspec-intent inside one is content, not an opener.
            if insidePlainFence {
                if line.hasPrefix("```") {
                    insidePlainFence = false
                }
                continue
            }
            if let spec = currentSpec {
                if line.hasPrefix("```") {
                    try close(spec, lines: currentLines, startingAt: blockStart, into: &intents)
                    currentSpec = nil
                    currentLines = []
                } else {
                    currentLines.append(rawLine)
                }
            } else if line.hasPrefix("```"), !line.dropFirst(3).hasPrefix(fenceLabel) {
                insidePlainFence = true
            } else if line.hasPrefix("```") {
                currentSpec = try specName(onFence: line, at: offset + 1)
                blockStart = offset + 1
            }
        }
        if let spec = currentSpec {
            throw IntentGrammarError(
                line: blockStart,
                text: "```\(fenceLabel) \(spec)",
                problem: "the block is never closed",
                hint: "close the block with a ``` line"
            )
        }
        return intents
    }

    /// The spec a `` ```haruspec-intent <spec> `` fence names — thrown at, not defaulted, when the
    /// name is missing: an unpaired block cannot excuse anything.
    private static func specName(onFence line: String, at lineNumber: Int) throws -> String {
        let spec = line.dropFirst(3).dropFirst(fenceLabel.count).trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else {
            throw IntentGrammarError(
                line: lineNumber,
                text: line,
                problem: "the block names no spec",
                hint: "open the block as ```\(fenceLabel) <spec> — the spec name pairs the "
                    + "declarations with the plan they excuse (e.g. ```\(fenceLabel) search.combine)"
            )
        }
        return spec
    }

    /// Parses one closed block into `intents`, refusing a spec that already has one — a second
    /// block would silently widen the first.
    private static func close(
        _ spec: String,
        lines: [String],
        startingAt blockStart: Int,
        into intents: inout [String: Intent]
    ) throws {
        guard intents[spec] == nil else {
            throw IntentGrammarError(
                line: blockStart,
                text: "```\(fenceLabel) \(spec)",
                problem: "spec \"\(spec)\" already has an intent block",
                hint: "declare each spec's intent in one block; a second block would "
                    + "silently widen the first"
            )
        }
        intents[spec] = try intent(parsing: lines.joined(separator: "\n"), lineOffset: blockStart)
    }

    /// Parses declaration lines (one per line; blank lines and `//` comments allowed) into an
    /// `Intent`. `lineOffset` shifts error line numbers to the enclosing document's.
    public static func intent(parsing text: String, lineOffset: Int = 0) throws -> Intent {
        var intent = Intent()
        for (offset, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
            var parser = DeclarationParser(line: trimmed, number: lineOffset + offset + 1)
            try parser.parse(into: &intent)
        }
        return intent
    }
}

/// Where and why a declaration failed to parse, with the spelling that would have.
public struct IntentGrammarError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let text: String
    public let problem: String
    public let hint: String

    public var description: String {
        "intent line \(line): \(problem)\n    \(text)\n\(hint)"
    }
}

/// A single declaration line's recursive-descent parser — `Name(arguments)` with string literals,
/// `label:` argument names, and `.domain` names, exactly the DSL's spellings.
struct DeclarationParser {
    let line: String
    let number: Int
    var index: String.Index

    init(line: String, number: Int) {
        self.line = line
        self.number = number
        index = line.startIndex
    }

    /// The bare one-string declarations, by the `Intent` list each appends to. The labeled ones carry
    /// their argument label (`Drops(synchronizationOf:)`); the bare ones `nil`. None takes a modifier.
    private static var stringDeclarations: [String: (label: String?, list: WritableKeyPath<Intent, [String]>)] {
        [
            "Awaits": (nil, \.expectedOrderingAdditions),
            "Drops": ("synchronizationOf", \.expectedOrderingLosses),
            "Accepts": ("uncaptured", \.acceptedBlindSpots)
        ]
    }

    /// A parsed declaration head, before its modifiers: what the chained `.modifier(…)` calls may
    /// narrow. A head that admits no modifier has already been appended.
    enum Head {
        case event(WritableKeyPath<Intent, [Intent.EventChange]>, label: String)
        case value(label: String, fields: [String])
        case unmodifiable(String)

        var allowedModifiers: [String] {
            switch self {
            case .event: ["when"]
            case .value: ["to", "increases", "decreases", "within", "when"]
            case .unmodifiable: []
            }
        }
    }

    mutating func parse(into intent: inout Intent) throws {
        let name = try identifier(expected: "a declaration")
        try expect("(")
        let head = try head(name, into: &intent)
        try expect(")")
        var modifiers = Modifiers()
        while consume(".") {
            try modifier(on: head, into: &modifiers)
        }
        switch head {
        case let .event(list, label):
            intent[keyPath: list].append(Intent.EventChange(label, when: modifiers.conditions))
        case let .value(label, fields):
            let fields: [String?] = fields.isEmpty ? [nil] : fields
            for field in fields {
                intent.expectedValueChanges.append(
                    Intent.ValueChange(label, field: field, relation: modifiers.relation, when: modifiers.conditions)
                )
            }
        case .unmodifiable:
            break
        }
        skipSpaces()
        guard index == line.endIndex else {
            throw error("unexpected trailing text", hint: "one declaration per line")
        }
    }

    mutating func head(_ name: String, into intent: inout Intent) throws -> Head {
        if let (label, list) = Self.stringDeclarations[name] {
            if let label {
                try expectLabel(label)
            }
            try intent[keyPath: list].append(string())
            return .unmodifiable(name)
        }
        switch name {
        case "Emits":
            return try .event(\.expectedNewEvents, label: string())
        case "Omits":
            return try .event(\.expectedRemovedEvents, label: string())
        case "Reorders":
            try intent.expectedReorders.append(contentsOf: strings())
        case "Changes":
            let label = try string()
            var fields: [String] = []
            if consume(",") {
                try expectLabel("field")
                fields = try strings()
            }
            return .value(label: label, fields: fields)
        case "Relaxes":
            try expectLabel("orderingOf")
            try intent.expectedOrderingRelaxations.append(domain())
        case "Moves":
            try intent.expectedDomainMigrations.append(move())
        default:
            throw error(
                "\"\(name)\" is not a declaration",
                hint: "declarations are Emits, Omits, Changes, Reorders, Awaits, "
                    + "Drops(synchronizationOf:), Relaxes(orderingOf:), Moves(from:to:), "
                    + "and Accepts(uncaptured:)"
            )
        }
        return .unmodifiable(name)
    }

    /// `Moves("a", "b", from: X, to: Y)` or `Moves(everythingFrom: X, to: Y)`.
    mutating func move() throws -> Intent.DomainMove {
        skipSpaces()
        if peek() != "\"" {
            try expectLabel("everythingFrom")
            let origin = try domain()
            try expect(",")
            try expectLabel("to")
            return try Intent.DomainMove(from: origin, to: domain())
        }
        var labels = try [string()]
        while consume(",") {
            skipSpaces()
            if peek() == "\"" {
                try labels.append(string())
            } else {
                try expectLabel("from")
                let origin = try domain()
                try expect(",")
                try expectLabel("to")
                return try Intent.DomainMove(labels: labels, from: origin, to: domain())
            }
        }
        throw error(
            "Moves needs its domains",
            hint: "Moves(\"Label\", from: .main, to: .ambient) — or Moves(everythingFrom:to:) "
                + "for the explicit wholesale form"
        )
    }

    /// `.main`, `.ambient`, `.queue("label")`, `.actor("Type")` — or `.actor(Type.self)`, so a
    /// declaration pasted from Swift parses unchanged.
    mutating func domain() throws -> DomainName {
        try expect(".")
        let name = try identifier(expected: "a domain")
        switch name {
        case "main": return .main
        case "ambient": return .ambient
        case "queue":
            try expect("(")
            let label = try string()
            try expect(")")
            return .queue(label)
        case "actor":
            try expect("(")
            let type: String
            skipSpaces()
            if peek() == "\"" {
                type = try string()
            } else {
                type = try identifier(expected: "an actor type")
                try expect(".")
                try expectLabel("self", colon: false)
            }
            try expect(")")
            return .actor(type)
        default:
            throw error(
                "\".\(name)\" is not a domain",
                hint: "domains are .main, .ambient, .queue(\"label\"), and .actor(\"Type\")"
            )
        }
    }

    // MARK: - Tokens

    mutating func strings() throws -> [String] {
        var values = try [string()]
        while consume(",") {
            try values.append(string())
        }
        return values
    }

    mutating func string() throws -> String {
        skipSpaces()
        guard consume("\"") else {
            throw error("expected a quoted string", hint: "labels are quoted: Emits(\"CartDidChange\")")
        }
        var value = ""
        while index < line.endIndex {
            let character = line[index]
            index = line.index(after: index)
            if character == "\"" {
                return value
            }
            value.append(character)
        }
        throw error("unterminated string", hint: "close the quote")
    }

    mutating func identifier(expected: String) throws -> String {
        skipSpaces()
        var name = ""
        while index < line.endIndex, line[index].isLetter || line[index].isNumber || line[index] == "_" {
            name.append(line[index])
            index = line.index(after: index)
        }
        guard !name.isEmpty else {
            throw error("expected \(expected)", hint: "e.g. Changes(\"Search.query\")")
        }
        return name
    }

    mutating func expectLabel(_ label: String, colon: Bool = true) throws {
        let name = try identifier(expected: "\"\(label)\(colon ? ":" : "")\"")
        guard name == label else {
            throw error("expected \"\(label)\(colon ? ":" : "")\", found \"\(name)\"", hint: "")
        }
        if colon {
            try expect(":")
        }
    }

    mutating func expect(_ character: Character) throws {
        skipSpaces()
        guard consume(character) else {
            throw error("expected \"\(character)\"", hint: "")
        }
    }

    mutating func consume(_ character: Character) -> Bool {
        skipSpaces()
        guard index < line.endIndex, line[index] == character else {
            return false
        }
        index = line.index(after: index)
        return true
    }

    mutating func peek() -> Character? {
        skipSpaces()
        return index < line.endIndex ? line[index] : nil
    }

    mutating func skipSpaces() {
        while index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
        }
    }

    func error(_ problem: String, hint: String) -> IntentGrammarError {
        IntentGrammarError(line: number, text: line, problem: problem, hint: hint)
    }
}
