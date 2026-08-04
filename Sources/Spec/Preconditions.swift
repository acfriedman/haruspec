import Foundation

// `.after` declares what an op is *expected* to follow, not what exploration will enforce. A
// differential oracle has no expected value an out-of-order call could contradict — both branches see
// the same sequence, so the only question is whether they agree — which makes remove-before-add an
// input worth spending budget on rather than one worth filtering away. What a soft precondition buys
// instead is a *label*: the share of the sweep that broke one, and the name of the one a failing order
// broke. `.requires` is the hard gate for the rare op that would trap out of order (see `Op`).

// MARK: - Soft preconditions

/// Each op's declared `.after` labels, keyed by op label — the form `violatedPreconditions` reads, and
/// the only form available on the replay path, where an ordering is a bare label sequence.
func preconditions(of ops: [Op<some Any>]) -> [String: [String]] {
    var declared: [String: [String]] = [:]
    for operation in ops where !operation.afters.isEmpty {
        declared[operation.label, default: []] += operation.afters
    }
    return declared
}

/// The soft preconditions a label sequence breaks, rendered as `"removeMug after addMug"` — how the
/// out-of-order stratum is selected, and the line a verdict prints beside a failing order.
func violatedPreconditions(in order: [String], declaredBy declared: [String: [String]]) -> [String] {
    guard !declared.isEmpty else {
        return []
    }
    var ran = Set<String>()
    var violations: [String] = []
    var reported = Set<String>()
    for label in order {
        for gate in declared[label] ?? [] where !ran.contains(gate) {
            let text = "\(label) after \(gate)"
            if reported.insert(text).inserted {
                violations.append(text)
            }
        }
        ran.insert(label)
    }
    return violations
}

extension Spec {
    /// How many of these orderings break a declared precondition — the stratum size a verdict reports.
    func outOfOrderCount(among orderings: [[String]]) -> Int {
        let declared = preconditions(of: operations)
        return orderings.filter { !violatedPreconditions(in: $0, declaredBy: declared).isEmpty }.count
    }

    /// The preconditions this label sequence breaks, for the verdict's failing order.
    func preconditionViolations(in order: [String]) -> [String] {
        violatedPreconditions(in: order, declaredBy: preconditions(of: operations))
    }
}
