import Foundation

// The modifiers that narrow a declaration — the data half of "precise intent". A bare declaration
// is a standing excuse keyed on (kind, label): `Changes("Receipt", field: "discountCents")` absorbs
// a discount that went up as happily as one that went down, in every probe. A modifier says *what*
// changes, so the declaration matches less and everything it rejects stays collateral — a tripwire
// instead of a blanket.
//
// Modifiers are data, never closures: a declaration must round-trip through the PR body's
// `haruspec-intent` block, the merged-intent union record-on-merge replays under, and the
// suggested-declaration offer a red comment prints. Every modifier has exactly one spelling.

/// The recorded seam inputs of the probe a divergence was observed in: seam key → the values that
/// seam read, in order (`CassetteData.tracks`). `nil` when the caller has no probe (a bare
/// `haruspec diff` over two traces), in which case no input condition can hold.
public typealias ProbeInputs = [String: [CanonicalValue]]

/// How a declared value change is narrowed: the relation the candidate's value must bear to the
/// baseline's for the declaration to match. Exactly one per declaration.
public enum ValueRelation: Sendable, Equatable, Codable {
    /// The new value is exactly this — `.to(11363)`, `.to("SAVE10")`, `.to(true)`.
    case to(CanonicalValue)
    /// The value went up (both sides numeric) — `.increases()`.
    case increases
    /// The value went down (both sides numeric) — `.decreases()`.
    case decreases
    /// The new value lies in this range (numeric) — `.within(1 ... 64)`.
    case within(ClosedRange<Double>)

    /// Whether the relation holds between the two observed values. A relation that needs numbers
    /// and finds none does not hold — narrowing never widens by accident.
    func holds(baseline: CanonicalValue?, candidate: CanonicalValue?) -> Bool {
        guard let candidate else {
            return false
        }
        switch self {
        case let .to(value):
            return candidate.sameValue(as: value)
        case .increases:
            guard let before = baseline?.numericValue, let after = candidate.numericValue else {
                return false
            }
            return after > before
        case .decreases:
            guard let before = baseline?.numericValue, let after = candidate.numericValue else {
                return false
            }
            return after < before
        case let .within(range):
            guard let after = candidate.numericValue else {
                return false
            }
            return range.contains(after)
        }
    }

    /// The modifier's one spelling, as chained onto a declaration: `.to(11363)`.
    var dslText: String {
        switch self {
        case let .to(value): ".to(\(value.dslText))"
        case .increases: ".increases()"
        case .decreases: ".decreases()"
        case let .within(range):
            ".within(\(CanonicalValue.dslNumber(range.lowerBound)) ... \(CanonicalValue.dslNumber(range.upperBound)))"
        }
    }
}

/// A probe-input condition on a declaration — `.when("applyPromo.code", is: "SAVE10")`: the
/// declaration matches only in a probe whose recorded reads of that seam all returned the value.
///
/// "All" rather than "any", because a seam read several times in one probe (`add.quantity` across
/// three adds) cannot yet be attributed to the one event that diverged; until op identity per event
/// lands, a mixed probe leaves the divergence collateral rather than absorbing it on a partial match.
public struct InputCondition: Sendable, Equatable, Codable {
    public var seam: String
    public var value: CanonicalValue

    public init(seam: String, is value: CanonicalValue) {
        self.seam = seam
        self.value = value
    }

    func holds(in inputs: ProbeInputs?) -> Bool {
        guard let track = inputs?[seam], !track.isEmpty else {
            return false
        }
        return track.allSatisfy { $0.sameValue(as: value) }
    }

    var dslText: String {
        ".when(\"\(seam)\", is: \(value.dslText))"
    }
}

extension [InputCondition] {
    /// Every condition holds in these inputs; an empty list holds vacuously (the bare declaration).
    func allHold(in inputs: ProbeInputs?) -> Bool {
        allSatisfy { $0.holds(in: inputs) }
    }

    var dslText: String {
        map(\.dslText).joined()
    }
}

extension CanonicalValue {
    /// `.int` and `.double` as one number, so a declared `11363` matches a recorded `11363.0`.
    var numericValue: Double? {
        switch self {
        case let .int(int): Double(int)
        case let .double(double): double
        default: nil
        }
    }

    /// A leaf value — the only shape a modifier's literal can spell.
    var isScalar: Bool {
        switch self {
        case .null, .bool, .int, .double, .string: true
        case .array, .object: false
        }
    }

    /// Equality that treats the numeric cases as one number and everything else exactly.
    func sameValue(as other: CanonicalValue) -> Bool {
        if let mine = numericValue, let theirs = other.numericValue {
            return mine == theirs
        }
        return self == other
    }

    /// The literal spelling inside a modifier — `11363`, `1.5`, `"SAVE10"`, `true`, `null` — which
    /// `IntentGrammar` parses back to the same value.
    ///
    /// - Precondition: `isScalar` — an array or object has no literal in the grammar.
    var dslText: String {
        switch self {
        case .null: "null"
        case let .bool(bool): bool ? "true" : "false"
        case let .int(int): String(int)
        case let .double(double): Self.dslNumber(double)
        case let .string(string): "\"\(string)\""
        case .array, .object:
            preconditionFailure("a modifier literal must be a scalar, not \(canonicalString)")
        }
    }

    /// A number as the grammar spells it: whole values without a fractional part.
    static func dslNumber(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }
}
