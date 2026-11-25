import Foundation

// The offer a red verdict makes, derived from every failing case the sweep walked rather than
// from the one case it met first. One case proves one value (`.to(32)`); several cases prove a
// shape — the same value every time, a direction, or a range — and the offer names the narrowest
// shape all of them satisfy. A single case still yields its `.to(…)`. Every offer is scoped to
// the op the divergence was recorded under (`.only(in:)`) when every case agrees on it — the
// narrowest line the cases prove, which the author widens on purpose.

public extension Divergence {
    /// The declaration that would mark this divergence intended — the exact line the teaching loop
    /// offers on a red verdict, and a line `IntentGrammar` parses back.
    ///
    /// The narrowest line the divergence proves: a value mismatch with a scalar new value is
    /// offered as `.to(<value>)`, which pins exactly what this probe observed, and any divergence
    /// recorded under a declared op is scoped to it with `.only(in:)`. An author whose change is
    /// a direction, a range, or every op rather than one value widens it (`.increases()`,
    /// `.within(…)`, the bare field) — the loop pushes toward precision by default.
    ///
    /// `nil` for a divergence that is not expressible as intent (timing regressions) or whose
    /// domains did not resolve.
    var suggestedDeclaration: String? {
        suggestion(
            relation: candidateValue.flatMap { $0.isScalar ? ValueRelation.to($0) : nil },
            scope: op.map { .only(in: $0.label) }
        )
    }

    /// The declarations that would mark every gating divergence in `divergences` intended, one per
    /// (kind, label, field), each as narrow as the whole set allows. First-seen order.
    ///
    /// - Parameter divergences: The divergences of every failing case the sweep walked, in sweep order.
    /// - Returns: One declaration per (kind, label, field) of a gating divergence no declaration
    ///   rejected, in first-seen order; a kind not expressible as intent gets none.
    ///
    /// For a value mismatch seen in several cases: every new value the same → `.to(v)`; every case
    /// numeric and moving the same way → `.increases()` / `.decreases()`; every case numeric →
    /// `.within(min ... max)` over the new values; otherwise the bare field. Other kinds have one
    /// spelling, offered once. Every kind is scoped `.only(in:)` when all its cases share an op.
    ///
    /// A divergence a declaration already rejected (`rejectedBy`) gets no offer: the only line that
    /// would absorb it is wider than the one the author wrote, and that is theirs to choose.
    static func suggestedDeclarations(across divergences: [Divergence]) -> [String] {
        var order: [String] = []
        var groups: [String: [Divergence]] = [:]
        for divergence in divergences where divergence.isGating && divergence.rejectedBy.isEmpty {
            let key = "\(divergence.kind.rawValue)|\(divergence.label)|\(divergence.field ?? "")"
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(divergence)
        }
        return order.compactMap { key in
            let group = groups[key] ?? []
            guard let first = group.first else {
                return nil
            }
            let scope = scope(across: group)
            guard first.kind == .valueMismatch, group.count > 1 else {
                return first.suggestion(
                    relation: first.candidateValue.flatMap { $0.isScalar ? ValueRelation.to($0) : nil },
                    scope: scope
                )
            }
            return first.suggestion(relation: relation(across: group), scope: scope)
        }
    }

    /// Returns the op scope every case in `group` agrees on — the bare form when they don't, since it
    /// is then the narrowest provable one.
    ///
    /// - Parameter group: The divergences of one (kind, label, field), from every case.
    /// - Returns: `.only(in:)` naming the op every case was recorded under; `nil` when any case carries
    ///   no op or the ops differ.
    private static func scope(across group: [Divergence]) -> OpScope? {
        guard let op = group.first?.op?.label, group.allSatisfy({ $0.op?.label == op }) else {
            return nil
        }
        return .only(in: op)
    }

    /// Returns the narrowest relation every mismatch in `group` satisfies, or `nil` when only the bare
    /// field does.
    ///
    /// - Parameter group: The value mismatches of one (label, field), from every case.
    /// - Returns: `.to` when every new value is the same; `.increases` or `.decreases` when every case
    ///   is numeric and moves that way; `.within` over the new values when every case is numeric;
    ///   otherwise `nil`.
    private static func relation(across group: [Divergence]) -> ValueRelation? {
        let candidates = group.compactMap(\.candidateValue)
        guard candidates.count == group.count, candidates.allSatisfy(\.isScalar) else {
            return nil
        }
        if let pinned = candidates.first, candidates.allSatisfy({ $0.sameValue(as: pinned) }) {
            return .to(pinned)
        }
        let numeric = group.compactMap { divergence -> (before: Double, after: Double)? in
            guard let before = divergence.baselineValue?.numericValue,
                  let after = divergence.candidateValue?.numericValue else {
                return nil
            }
            return (before, after)
        }
        guard numeric.count == group.count else {
            return nil
        }
        if numeric.allSatisfy({ $0.after > $0.before }) {
            return .increases
        }
        if numeric.allSatisfy({ $0.after < $0.before }) {
            return .decreases
        }
        let afters = numeric.map(\.after)
        guard let low = afters.min(), let high = afters.max() else {
            return nil
        }
        return .within(low ... high)
    }

    /// One declaration text for this divergence's kind and label, with the modifiers given.
    ///
    /// - Parameters:
    ///   - relation: The value relation to narrow a value change with; `nil` for none.
    ///   - scope: The op scope to narrow with, for the kinds that take one; `nil` for none.
    /// - Returns: The declaration's DSL text; `nil` for a timing regression or a domain that did not
    ///   resolve.
    func suggestion(relation: ValueRelation?, scope: OpScope?) -> String? {
        let scoped = scope?.dslText ?? ""
        switch kind {
        case .unexpectedEvent:
            return "Emits(\(quoted(label)))" + scoped
        case .missingEvent:
            return "Omits(\(quoted(label)))" + scoped
        case .valueMismatch:
            return Intent.ValueChange(label, field: field, relation: relation, scope: scope).dslText
        case .orderingRelaxed:
            return fromDomain.flatMap(DomainName.init(recorded:))
                .map { "Relaxes(orderingOf: \($0.dslText))" }
        case .orderingLost:
            return "Drops(synchronizationOf: \(quoted(label)))"
        case .orderingAdded:
            return "Awaits(\(quoted(label)))"
        case .reordered:
            return "Reorders(\(quoted(label)))"
        case .domainMigration:
            guard let origin = fromDomain.flatMap(DomainName.init(recorded:)),
                  let destination = toDomain.flatMap(DomainName.init(recorded:)) else {
                return nil
            }
            return "Moves(\(quoted(label)), from: \(origin.dslText), to: \(destination.dslText))" + scoped
        case .timingRegression:
            return nil // not expressible as declared intent — always collateral
        }
    }
}

public extension Intent {
    /// The DSL spellings of every declaration that absorbs `divergence` given what the probe left
    /// behind — what a report names when it says which declaration a divergence was disclosed
    /// under. Empty for a divergence nothing declares.
    ///
    /// - Parameters:
    ///   - divergence: The divergence to look up.
    ///   - evidence: What the probe left behind; `.none` lets only unmodified declarations match.
    /// - Returns: The matching declarations' spellings, in declaration order; empty when nothing
    ///   declares `divergence`.
    func declarationsMatching(_ divergence: Divergence, evidence: ProbeEvidence = .none) -> [String] {
        declarations.filter { $0.matches(divergence, evidence) }.map(\.text)
    }

    func declarationsMatching(_ divergence: Divergence, inputs: ProbeInputs?) -> [String] {
        declarationsMatching(divergence, evidence: ProbeEvidence(inputs: inputs))
    }
}
