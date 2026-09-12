import Foundation

// The modifier half of the grammar: the chained `.modifier(…)` calls that narrow a declaration
// (`ValueRelation`, `InputCondition`) and the scalar literals they take. Kept beside the
// declaration parser so the two halves share its tokens; split out so each reads on its own.

extension DeclarationParser {
    /// The modifiers chained onto one declaration, accumulated in order of appearance.
    struct Modifiers {
        var relation: ValueRelation?
        var conditions: [InputCondition] = []
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
            preconditionFailure("allowedModifiers admitted an unhandled modifier \(name)")
        }
        try expect(")")
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

    // MARK: - Literals

    /// A scalar literal — `"text"`, `11363`, `1.5`, `-2`, `true`, `false`, `null` — exactly the
    /// spellings `CanonicalValue.dslText` renders.
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
