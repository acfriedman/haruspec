import Foundation

// The offer a red verdict makes, derived from every failing case the sweep walked rather than
// from the one case it met first. One case proves one value (`.to(32)`); several cases prove a
// shape — the same value every time, a direction, or a range — and the offer names the narrowest
// shape all of them satisfy. A single case still yields its `.to(…)`.

public extension Divergence {
    /// The declarations that would mark every gating divergence in `divergences` intended, one per
    /// (kind, label, field), each as narrow as the whole set allows. First-seen order.
    ///
    /// For a value mismatch seen in several cases: every new value the same → `.to(v)`; every case
    /// numeric and moving the same way → `.increases()` / `.decreases()`; every case numeric →
    /// `.within(min ... max)` over the new values; otherwise the bare field. Other kinds have one
    /// spelling, offered once.
    static func suggestedDeclarations(across divergences: [Divergence]) -> [String] {
        var order: [String] = []
        var groups: [String: [Divergence]] = [:]
        for divergence in divergences where divergence.isGating {
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
            guard first.kind == .valueMismatch, group.count > 1 else {
                return first.suggestedDeclaration
            }
            return Intent.ValueChange(first.label, field: first.field, relation: relation(across: group)).dslText
        }
    }

    /// The narrowest relation every mismatch in `group` satisfies, or `nil` when only the bare
    /// field does.
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
}

public extension Intent {
    /// The DSL spellings of every declaration that absorbs `divergence` in a probe that read
    /// `inputs` — what a report names when it says which declaration a divergence was disclosed
    /// under. Empty for a divergence nothing declares.
    func declarationsMatching(_ divergence: Divergence, inputs: ProbeInputs? = nil) -> [String] {
        declarations.filter { $0.matches(divergence, inputs) }.map(\.text)
    }
}
