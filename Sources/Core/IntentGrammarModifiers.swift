import Foundation

// The modifier half of the grammar: the chained `.modifier(…)` calls that narrow a declaration
// (`ValueRelation`, `InputCondition`, `OpScope`, `Position`) and the scalar literals they take.
// Kept beside the declaration parser so the two halves share its tokens; split out so each reads
// on its own.

extension DeclarationParser {
    /// The modifiers chained onto one declaration, accumulated in order of appearance.
    struct Modifiers {
        var relation: ValueRelation?
        var conditions: [InputCondition] = []
        var scope: OpScope?
        var position: Position?
    }

    /// One chained `.modifier(…)` — the `.` is already consumed. Each modifier has one spelling, and
    /// a head accepts only the modifiers that narrow it.
    mutating func modifier(on head: Head, into modifiers: inout Modifiers) throws {
        let name = try identifier(expected: "a modifier")
        guard head.allowedModifiers.contains(name) else {
            let allowed = head.allowedModifiers.map { ".\($0)" }.joined(separator: ", ")
            throw error(
                "\".\(name)\" does not narrow this declaration",
                hint: allowed.isEmpty
                    ? "this declaration takes no modifiers"
                    : "modifiers here are \(allowed) — e.g. "
                    + "Changes(\"Receipt\", field: \"discountCents\").increases()"
            )
        }
        try expect("(")
        if try !valueModifier(name, into: &modifiers), try !placementModifier(name, into: &modifiers) {
            preconditionFailure("allowedModifiers admitted an unhandled modifier \(name)")
        }
        try expect(")")
    }

    /// The modifiers about the value and the probe — `.to`, `.increases`, `.decreases`, `.within`,
    /// `.when`; `false` when `name` is none of them.
    private mutating func valueModifier(_ name: String, into modifiers: inout Modifiers) throws -> Bool {
        switch name {
        case "to":
            try relate(.to(value()), into: &modifiers)
        case "increases":
            try relate(.increases, into: &modifiers)
        case "decreases":
            try relate(.decreases, into: &modifiers)
        case "within":
            let lower = try numberLiteral()
            try expectEllipsis()
            let upper = try numberLiteral()
            guard lower <= upper else {
                throw error("an empty range", hint: ".within(lower ... upper) with lower ≤ upper")
            }
            try relate(.within(lower ... upper), into: &modifiers)
        case "when":
            let seam = try string()
            try expect(",")
            try expectLabel("is")
            try modifiers.conditions.append(InputCondition(seam: seam, is: value()))
        default:
            return false
        }
        return true
    }

    /// One value relation per declaration — a second is a contradiction, refused with both named.
    func relate(_ relation: ValueRelation, into modifiers: inout Modifiers) throws {
        if let existing = modifiers.relation {
            throw error(
                "\(relation.dslText) contradicts \(existing.dslText)",
                hint: "one value relation per declaration — say .to, .increases, .decreases, or .within, not two"
            )
        }
        modifiers.relation = relation
    }

    /// The modifiers about where the event was recorded — `.only(in:)`, `.once(per:)`, `.after`,
    /// `.before`; `false` when `name` is none of them.
    private mutating func placementModifier(_ name: String, into modifiers: inout Modifiers) throws -> Bool {
        switch name {
        case "only":
            try expectLabel("in")
            try scope(.only(in: string()), into: &modifiers)
        case "once":
            try expectLabel("per")
            try scope(.once(per: string()), into: &modifiers)
        case "after":
            try place(.after(string()), into: &modifiers)
        case "before":
            try place(.before(string()), into: &modifiers)
        default:
            return false
        }
        return true
    }

    /// One op scope per declaration — `.once(per:)` already says which op, so a second scope
    /// either repeats it or contradicts it.
    func scope(_ scope: OpScope, into modifiers: inout Modifiers) throws {
        if let existing = modifiers.scope {
            throw error(
                "\(scope.dslText) contradicts \(existing.dslText)",
                hint: "one op scope per declaration — say .only(in:) or .once(per:), not two"
            )
        }
        modifiers.scope = scope
    }

    /// One position per declaration.
    func place(_ position: Position, into modifiers: inout Modifiers) throws {
        if let existing = modifiers.position {
            throw error(
                "\(position.dslText) contradicts \(existing.dslText)",
                hint: "one position per declaration — say .after(_:) or .before(_:), not two"
            )
        }
        modifiers.position = position
    }

    // MARK: - Literals

    /// Parses the scalar literal at the cursor — `"text"`, `11363`, `1.5`, `-2`, `true`, `false`,
    /// `null` — in exactly the spellings ``CanonicalValue/dslText`` renders.
    ///
    /// - Returns: The literal's value; a whole number that fits `Int64` is `.int`, any other number
    ///   `.double`.
    /// - Throws: ``IntentGrammarError`` when the cursor holds no literal: an unterminated string, a
    ///   malformed number, or a bare word other than `true`, `false`, and `null`.
    mutating func value() throws -> CanonicalValue {
        skipSpaces()
        switch peek() {
        case "\"":
            return try .string(string())
        case let character? where character.isNumber || character == "-":
            let (text, isWhole) = try numberText()
            if isWhole, let int = Int64(text) {
                return .int(int)
            }
            guard let double = Double(text) else {
                throw error("\"\(text)\" is not a number", hint: "e.g. .to(11363) or .to(1.5)")
            }
            return .double(double)
        default:
            let word = try identifier(expected: "a value")
            switch word {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                throw error(
                    "\"\(word)\" is not a value",
                    hint: "values are quoted strings, numbers, true, false, and null"
                )
            }
        }
    }

    mutating func numberLiteral() throws -> Double {
        let (text, _) = try numberText()
        guard let double = Double(text) else {
            throw error("\"\(text)\" is not a number", hint: "e.g. .within(1 ... 64)")
        }
        return double
    }

    /// The characters of a numeric literal, and whether it had no fractional part.
    mutating func numberText() throws -> (text: String, isWhole: Bool) {
        skipSpaces()
        var text = ""
        var isWhole = true
        if consume("-") {
            text = "-"
        }
        while index < line.endIndex, line[index].isNumber || line[index] == "." {
            if line[index] == "." {
                // `1 ... 64` is a range, not a fraction: a dot followed by a dot ends the number,
                // and so does a second fractional dot.
                let next = line.index(after: index)
                if !isWhole || (next < line.endIndex && line[next] == ".") {
                    break
                }
                isWhole = false
            }
            text.append(line[index])
            index = line.index(after: index)
        }
        guard text != "", text != "-" else {
            throw error("expected a number", hint: "e.g. .within(1 ... 64)")
        }
        return (text, isWhole)
    }

    mutating func expectEllipsis() throws {
        skipSpaces()
        for _ in 0 ..< 3 {
            guard index < line.endIndex, line[index] == "." else {
                throw error("expected \"...\"", hint: "a range is spelled lower ... upper, e.g. .within(1 ... 64)")
            }
            index = line.index(after: index)
        }
    }
}
