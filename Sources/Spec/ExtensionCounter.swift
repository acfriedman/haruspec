import Foundation
import HaruspecSeams

// MARK: - Uniform sampling

/// Linear-extension counts per remaining-state, memoized — the weights that make a random walk uniform
/// over *orderings* rather than over next-op choices.
///
/// Why weights are needed at all: picking evenly among the available ops hands equal probability to
/// branches that hold unequal numbers of orderings. Over `{a, a, b, b}`, choosing `a` twice spends both
/// copies and forces the tail, so that branch contains one ordering — while the branch through `ab`
/// still contains two. Splitting evenly gives the first ordering ¼ and the other two ⅛ apiece, against
/// ⅙ each for a uniform sample. The distortion favours *clustered* runs of one op over interleavings,
/// which is a lean away from where order-dependence lives.
///
/// The fix is to weight each choice by how many orderings lie beneath it. The state that determines
/// that is just the per-label remaining counts — whether a label's `.requires` gate has opened is derivable
/// from them (a label has been placed iff fewer remain than were declared) — so the whole walk memoizes
/// on a mixed-radix encoding of those counts. Counts are `Double` because a real space overflows
/// `Int64` long before it stops being samplable; the values are only ever used as ratios.
struct ExtensionCounter {
    private let labels: [String]
    private let declared: [Int]
    private let gates: [[Int]]
    private let mustBeLast: [Bool]
    private let strides: [Int]
    private var counts: [Int]
    private var remaining: Int
    private var memo: [Int: Double] = [:]
    /// False when the state space is too large to memoize, which drops the walk back to unweighted.
    /// A biased sample still beats refusing to sample.
    private let isWeighted: Bool

    init(_ multiset: [Op<some Any>], stateLimit: Int = 1_000_000) {
        var labels: [String] = []
        var declared: [Int] = []
        var index: [String: Int] = [:]
        var gates: [[String]] = []
        var mustBeLast: [Bool] = []
        for operation in multiset {
            if let known = index[operation.label] {
                declared[known] += 1
            } else {
                index[operation.label] = labels.count
                labels.append(operation.label)
                declared.append(1)
                gates.append(operation.gates)
                mustBeLast.append(operation.mustBeLast)
            }
        }
        self.labels = labels
        self.declared = declared
        self.gates = gates.map { $0.compactMap { index[$0] } }
        self.mustBeLast = mustBeLast
        counts = declared
        remaining = declared.reduce(0, +)

        var strides: [Int] = []
        var stride = 1
        for count in declared {
            strides.append(stride)
            stride *= count + 1
        }
        self.strides = strides
        isWeighted = stride <= stateLimit
    }

    /// Picks one of `labels` (the frontier, by label) with probability proportional to the orderings
    /// beneath it. Falls back to an even pick when the space is too large to count.
    mutating func choose(from labels: [String], using rng: inout SplitMix64) -> Int {
        guard isWeighted, labels.count > 1 else {
            return Int(rng.next() % UInt64(Swift.max(1, labels.count)))
        }
        let weights = labels.map { label -> Double in
            guard let slot = slot(of: label) else { return 0 }
            counts[slot] -= 1; remaining -= 1
            defer { counts[slot] += 1; remaining += 1 }
            return extensions()
        }
        let total = weights.reduce(0, +)
        guard total > 0 else {
            return Int(rng.next() % UInt64(labels.count))
        }
        var threshold = Double.random(in: 0 ..< total, using: &rng)
        for (index, weight) in weights.enumerated() {
            threshold -= weight
            if threshold < 0 {
                return index
            }
        }
        return weights.count - 1 // floating-point residue only
    }

    /// The exact number of orderings the whole partial order admits, or `nil` when the state space was
    /// too large to count. Far better than the capped walk where it applies: the example spec's 15-item
    /// multiset is 1,362,160,800 orderings over only 2,916 reachable states, which the walk would give up
    /// on at 100,000 and report as a lower bound.
    mutating func totalExtensions() -> Double? {
        guard isWeighted else {
            return nil
        }
        reset()
        return extensions()
    }

    /// Restores the full multiset for the next walk. The memo is deliberately kept — it is a property of
    /// the partial order, not of one walk, which is what makes weighting cheap across a whole sample.
    mutating func reset() {
        counts = declared
        remaining = declared.reduce(0, +)
    }

    /// Orderings of the current remaining state.
    private mutating func extensions() -> Double {
        if remaining == 0 {
            return 1
        }
        let key = zip(counts, strides).reduce(0) { $0 + $1.0 * $1.1 }
        if let known = memo[key] {
            return known
        }
        var total: Double = 0
        for slot in counts.indices where counts[slot] > 0 {
            guard gates[slot].allSatisfy({ counts[$0] < declared[$0] }) else { continue }
            if mustBeLast[slot], remaining > 1 {
                continue
            }
            counts[slot] -= 1; remaining -= 1
            total += extensions()
            counts[slot] += 1; remaining += 1
        }
        memo[key] = total
        return total
    }

    /// Records that the walk placed `label`, so subsequent weights are conditioned on it.
    mutating func take(_ label: String) {
        guard isWeighted, let slot = slot(of: label) else { return }
        counts[slot] -= 1
        remaining -= 1
    }

    private func slot(of label: String) -> Int? {
        // Frontier labels are few; a linear scan beats hashing here.
        labels.firstIndex(of: label)
    }
}
