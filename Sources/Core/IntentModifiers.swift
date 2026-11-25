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
/// seam read, in order (``CassetteData/tracks``). `nil` when the caller has no probe (a bare
/// `haruspec diff` over two traces), in which case no input condition can hold.
public typealias ProbeInputs = [String: [CanonicalValue]]

/// What a probe left behind for a declaration to check beyond the divergence itself: its seam
/// inputs, both traces as the diff aligned them, and the comparison's other divergences.
///
/// `.when` reads the inputs, `.after` / `.before` the traces, `.once(per:)` the divergences.
/// Anything absent fails closed — a modifier that cannot be checked does not hold, and the
/// divergence stays collateral. Only the op scope (`.only(in:)`) needs none of this: the op rides
/// on the divergence itself.
public struct ProbeEvidence: Sendable {
    public var inputs: ProbeInputs?
    /// Both sides' events exactly as the diff aligned them — canonicalized under the diff's
    /// comparison, so a divergence's `baselineSeq` / `candidateSeq` indexes into them.
    public var baseline: [TraceEvent]
    public var candidate: [TraceEvent]
    /// Every divergence of the comparison being classified, for a cardinality modifier to count
    /// against. ``TraceDiff/classified(against:evidence:)`` fills it from the diff it classifies.
    public var divergences: [Divergence]

    /// Creates the evidence a modifier is checked against, canonicalizing both traces under
    /// `comparison` so their sequence numbers are the ones the divergences carry.
    ///
    /// - Parameters:
    ///   - inputs: The probe's inputs; `nil` when the probe had none.
    ///   - baseline: The recorded trace; `nil` leaves `baseline` empty.
    ///   - candidate: The candidate trace; `nil` leaves `candidate` empty.
    ///   - comparison: The comparison the diff ran under; `.strict` when the caller has none.
    ///   - divergences: Every divergence of the comparison being classified; empty when the
    ///     comparison is not known.
    public init(
        inputs: ProbeInputs? = nil,
        baseline: Trace? = nil,
        candidate: Trace? = nil,
        comparison: Comparison = .strict,
        divergences: [Divergence] = []
    ) {
        self.inputs = inputs
        self.baseline = baseline.map { Canonicalizer.canonicalize($0, comparison: comparison).events } ?? []
        self.candidate = candidate.map { Canonicalizer.canonicalize($0, comparison: comparison).events } ?? []
        self.divergences = divergences
    }

    /// No probe at all: an unconditioned or op-scoped declaration can still hold; nothing else can.
    public static let none = ProbeEvidence()

    /// The divergences a cardinality check counts over — the comparison's when known, else the
    /// one being matched (which then trivially counts once).
    func siblings(of divergence: Divergence) -> [Divergence] {
        divergences.isEmpty ? [divergence] : divergences
    }
}

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
/// three adds) cannot be attributed to the one event that diverged: a read is not an event, so it
/// carries no op. A mixed probe leaves the divergence collateral rather than absorbing it on a
/// partial match.
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
        ".when(\(quoted(seam)), is: \(value.dslText))"
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

/// Which declared op a declaration is scoped to, by the label the spec's ordering gives the op.
///
/// `.only(in: "checkout")`: the divergence was recorded under that op. `.once(per: "add")`: under
/// that op, and the only one of its kind and label in that *application* of the op — a second one
/// in the same `add` is the tripwire, and leaves both collateral. Either fails closed for a
/// divergence that carries no op (an end-state snapshot; a golden recorded before ops were stamped).
public enum OpScope: Sendable, Equatable, Codable {
    case only(in: String)
    case once(per: String)

    func holds(for divergence: Divergence, among siblings: [Divergence]) -> Bool {
        guard let op = divergence.op, op.label == self.op else {
            return false
        }
        switch self {
        case .only:
            return true
        case .once:
            let alike = siblings.filter {
                $0.kind == divergence.kind && $0.label == divergence.label && $0.field == divergence.field && $0
                    .op == op
            }
            return alike.count == 1
        }
    }

    var op: String {
        switch self {
        case let .only(op), let .once(op): op
        }
    }

    var dslText: String {
        switch self {
        case let .only(op): ".only(in: \(quoted(op)))"
        case let .once(op): ".once(per: \(quoted(op)))"
        }
    }
}

extension OpScope? {
    /// Whether a declaration with this scope is *about* `divergence` at all: scoped to the op it
    /// was recorded under, or unscoped.
    ///
    /// The scope names where the declaration applies; only the modifiers that say what to expect
    /// there (`.once`'s count, a relation, a position, an input) can reject.
    func isAbout(_ divergence: Divergence) -> Bool {
        map { $0.op == divergence.op?.label } ?? true
    }
}

/// Where a declared event sits relative to another, by label — `.after("CartDidChange")`: some
/// event with that label precedes it.
///
/// Within the same application of the same op when the event carries one; anywhere in the trace
/// when it does not. Checked on the side the event exists on: the candidate for `Emits`, the baseline for `Omits`.
/// `Reorders(_, before:)` checks both — the event now sits before the anchor in the candidate and
/// sat after it in the baseline, so a move in any other direction stays collateral.
public enum Position: Sendable, Equatable, Codable {
    case after(String)
    case before(String)

    /// The same anchor, the other way round — what the baseline must show for a directed reorder.
    var inverted: Position {
        switch self {
        case let .after(anchor): .before(anchor)
        case let .before(anchor): .after(anchor)
        }
    }

    /// Whether the event at `seq` in `events` sits as declared relative to some anchor-labeled event.
    func holds(at seq: Int?, in events: [TraceEvent]) -> Bool {
        guard let seq, let event = events.first(where: { $0.seq == seq }) else {
            return false
        }
        return events.contains { other in
            other.label == anchor
                && (event.op == nil || other.op == event.op)
                && (isAfter ? other.seq < seq : other.seq > seq)
        }
    }

    var anchor: String {
        switch self {
        case let .after(anchor), let .before(anchor): anchor
        }
    }

    private var isAfter: Bool {
        if case .after = self {
            true
        } else {
            false
        }
    }

    /// The chained spelling — `.after("CartDidChange")`.
    var dslText: String {
        switch self {
        case let .after(anchor): ".after(\(quoted(anchor)))"
        case let .before(anchor): ".before(\(quoted(anchor)))"
        }
    }

    /// The argument spelling `Reorders` uses — `before: "CartDidChange"`.
    var argumentText: String {
        switch self {
        case let .after(anchor): "after: \(quoted(anchor))"
        case let .before(anchor): "before: \(quoted(anchor))"
        }
    }
}

extension CanonicalValue {
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

    /// `.int` and `.double` as one number, so a declared `11363` matches a recorded `11363.0`.
    var numericValue: Double? {
        switch self {
        case let .int(int): Double(int)
        case let .double(double): double
        default: nil
        }
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
        case let .string(string): quoted(string)
        case .array, .object:
            preconditionFailure("a modifier literal must be a scalar, not \(canonicalString)")
        }
    }

    /// A number as the grammar spells it: whole values without a fractional part.
    static func dslNumber(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }
}

/// A string as every declaration spells one: double-quoted, verbatim.
func quoted(_ text: String) -> String {
    "\"\(text)\""
}
