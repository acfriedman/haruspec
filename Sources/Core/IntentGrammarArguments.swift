import Foundation

// The structured arguments a declaration head takes — a directed reorder, a domain move, a domain
// name — parsed with the same tokens as the head itself.

extension DeclarationParser {
    /// `Reorders("a", "b")`, or directed: `Reorders("a", before: "M")` / `Reorders("a", after: "M")`.
    mutating func reorders() throws -> [Intent.Reorder] {
        var labels = try [string()]
        var position: Position?
        while consume(",") {
            skipSpaces()
            if peek() == "\"" {
                try labels.append(string())
                continue
            }
            let direction = try identifier(expected: "\"before:\" or \"after:\"")
            guard direction == "before" || direction == "after" else {
                throw error(
                    "\"\(direction)\" is not a direction",
                    hint: "Reorders(\"Label\", before: \"Anchor\") or Reorders(\"Label\", after: \"Anchor\")"
                )
            }
            try expect(":")
            let anchor = try string()
            position = direction == "before" ? .before(anchor) : .after(anchor)
            break
        }
        return labels.map { Intent.Reorder($0, position: position) }
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
}
