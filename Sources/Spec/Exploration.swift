import Foundation
import HaruspecCore
import HaruspecSeams

// How much interrogation a spec can afford, and how that is spent across the two axes.
//
// The two numbers used to meet by accident. `Ordering(max:)` was author-facing while the 64 seam
// variants multiplying it were a private constant — the larger multiplier with no dial. Worse, the
// variants were generated inside the ordering loop from one fixed seed, so a nominally ordering × seam
// sweep re-tried the *same* 64 vectors against every ordering: 6,400 runs exploring 64 distinct
// inputs, a 1-D sweep wearing a 2-D shape.
//
// `Budget(runs:)` makes the total the author's number and splits it across both axes; generation
// reseeds per ordering so the axes are independent. And because a capped run covers a fraction of what
// was declared, the fraction rides back on the verdict — a spec that swept 2% of its orderings should
// say 2%, not "50 orderings explored" as though 50 were the number.

/// What a run actually covered — the denominator behind a verdict.
public struct Exploration: Codable, Sendable, Equatable {
    public let orderingsExplored: Int
    /// Valid orderings of the declared partial order. A *lower bound* when `orderingsAreExact` is
    /// false: counting stops at a limit rather than walking a space that grows factorially.
    public let orderingsAvailable: Int
    public let orderingsAreExact: Bool
    /// Seam cassettes generated per ordering — 1 when the spec declares no seam domain.
    public let variantsPerOrdering: Int

    public init(
        orderingsExplored: Int,
        orderingsAvailable: Int,
        orderingsAreExact: Bool,
        variantsPerOrdering: Int
    ) {
        self.orderingsExplored = orderingsExplored
        self.orderingsAvailable = orderingsAvailable
        self.orderingsAreExact = orderingsAreExact
        self.variantsPerOrdering = variantsPerOrdering
    }

    /// Differential runs spent: each drives the baseline and the candidate once.
    public var runs: Int {
        orderingsExplored * variantsPerOrdering
    }

    /// The share of valid orderings explored, or `nil` when the available count is a lower bound with
    /// nothing meaningful to divide by.
    public var orderingFraction: Double? {
        guard orderingsAvailable > 0 else {
            return nil
        }
        return Swift.min(1, Double(orderingsExplored) / Double(orderingsAvailable))
    }

    /// Whether the declared ordering surface was covered exhaustively — the case where the fraction
    /// needs no caveat.
    public var isExhaustive: Bool {
        orderingsAreExact && orderingsExplored >= orderingsAvailable
    }

    /// One line for the verdict: `3200 runs · 50 of 2520 orderings (2%) × 64 seam variants`.
    public var summary: String {
        var text = "\(runs) run\(runs == 1 ? "" : "s") · "
        if isExhaustive {
            text += "all \(orderingsAvailable) ordering\(orderingsAvailable == 1 ? "" : "s")"
        } else {
            let bound = orderingsAreExact ? "" : "≥"
            text += "\(orderingsExplored) of \(bound)\(orderingsAvailable) orderings"
            if let fraction = orderingFraction {
                text += " (\(Self.percent(fraction)))"
            }
        }
        if variantsPerOrdering > 1 {
            text += " × \(variantsPerOrdering) seam variants"
        }
        return text
    }

    /// Rounded, except that a non-zero share never renders as `0%` — "we covered none of it" and
    /// "we covered a sliver" are different findings.
    private static func percent(_ fraction: Double) -> String {
        let rounded = Int((fraction * 100).rounded())
        return rounded == 0 ? "<1%" : "\(rounded)%"
    }
}

// MARK: - The resolved plan

/// The exact work one verify or record will do: which orderings, and how the seam budget is spent
/// against each. Shared by `verify(against:)` and `record()` so the live differential and the recorded
/// plan explore the same surface by construction rather than by two copies of the same loop.
struct ExplorationPlan<S> {
    let orderings: [[Op<S>]]
    let variantsPerOrdering: Int
    let exploration: Exploration
    private let golden: CassetteData
    private let domains: [String: SeamDomain]
    private let seed: UInt64

    init(
        orderings: [[Op<S>]],
        variantsPerOrdering: Int,
        exploration: Exploration,
        golden: CassetteData,
        domains: [String: SeamDomain],
        seed: UInt64
    ) {
        self.orderings = orderings
        self.variantsPerOrdering = variantsPerOrdering
        self.exploration = exploration
        self.golden = golden
        self.domains = domains
        self.seed = seed
    }

    /// The seam cassettes to drive ordering `index` with — an *independent* sample per ordering, which
    /// is what makes the sweep two-dimensional. Ordering 0 keeps the base seed, so a single-ordering
    /// spec generates exactly what it always did.
    ///
    /// Only the random tail moves: the generator's leading boundary variants are the same under every
    /// ordering, deliberately. Every edge tried under every ordering is where an order-dependent edge
    /// bug lives, and it is the cross-product worth spending the budget on.
    func cassettes(forOrdering index: Int) -> [CassetteData] {
        guard !domains.isEmpty else {
            return [golden]
        }
        return golden.generatedVariants(
            count: variantsPerOrdering,
            varying: domains,
            seed: seed &+ UInt64(index)
        )
    }
}

extension Spec {
    /// Resolve what this spec declared into the work a run will actually do.
    func explorationPlan(golden: CassetteData) -> ExplorationPlan<S> {
        let hasSeams = !seamDomains.isEmpty
        let available = exploreOrdering
            ? countLinearExtensions(operations, repeating: orderingRepeats, limit: SpecDefaults.orderingCountLimit)
            : (count: 1, exact: true)

        // Resolve the budget *before* enumerating: taking a prefix of an exhaustive enumeration would
        // reintroduce exactly the prefix bias the sampling below exists to remove.
        // Against what the ordering axis can *actually* supply, not the declared cap: a spec whose
        // partial order admits 2 orderings would otherwise spend a 200-run budget on 22 runs.
        let split = ExplorationBudget.split(
            orderingCap: exploreOrdering ? Swift.min(maxOrderings, available.count) : 1,
            variants: hasSeams ? SpecDefaults.variantCount : 1,
            budget: explorationBudget
        )
        let orderings = exploreOrdering
            ? linearExtensions(operations, max: split.orderings, repeating: orderingRepeats)
            : [operations]

        return ExplorationPlan(
            orderings: orderings,
            variantsPerOrdering: split.variants,
            exploration: Exploration(
                orderingsExplored: orderings.count,
                orderingsAvailable: Swift.max(available.count, orderings.count),
                orderingsAreExact: available.exact,
                variantsPerOrdering: split.variants
            ),
            golden: golden,
            domains: seamDomains,
            seed: SpecDefaults.seed
        )
    }
}

/// Splitting a declared run budget across the two axes.
enum ExplorationBudget {
    /// Shrink both axes by the same factor rather than draining one to fill the other: the two find
    /// different bugs (ordering reaches code a second seam value cannot; a seam value is what caught
    /// the dogfood's one-cent divergence), so a budget that zeroes either axis is not a smaller sweep,
    /// it is a different one. Scaling the declared shape by `√(budget / full)` keeps its aspect ratio.
    ///
    /// With no budget declared, both axes take their own size — `Ordering(max:)` × 64.
    static func split(orderingCap: Int, variants: Int, budget: Int?) -> (orderings: Int, variants: Int) {
        let cap = Swift.max(1, orderingCap)
        let fullVariants = Swift.max(1, variants)
        guard let budget, budget > 0 else {
            return (cap, fullVariants)
        }
        guard fullVariants > 1 else {
            return (Swift.min(cap, budget), 1) // no seam axis to spend on
        }
        let full = cap * fullVariants
        guard budget < full else {
            // Bought more than the declared shape: the extra goes to seam breadth, since the ordering
            // axis is capped by what the author declared.
            return (cap, Swift.max(1, budget / cap))
        }
        let scale = (Double(budget) / Double(full)).squareRoot()
        let orderings = Swift.min(cap, Swift.max(1, Int((Double(cap) * scale).rounded())))
        return (orderings, Swift.max(1, budget / orderings))
    }
}

// MARK: - Linear extensions

/// Enumerate the linear extensions of the declared partial order (respecting `.after` and `.last`) when
/// the space fits in `max`, and *sample* `max` of them when it doesn't.
///
/// Sampling is the point. Depth-first truncation returned the first `max` extensions in enumeration
/// order, which all share a long common prefix — the example spec's 50-of-2,520 slice varied only in
/// its tail. A random walk over the available-op frontier spreads the same budget across the space.
/// It is not uniform over extensions (it picks uniformly among *available distinct labels*, which
/// weights differently), but it is unbiased with respect to position, which is the bias that mattered.
///
/// Over a *multiset* of ops: a repeatable op contributes `repeating` occurrences, so orderings explore
/// applying an operation more than once — which is where merge-into-existing and
/// remove-what-is-not-there branches live. Ops marked `.once()` (and `.last()`, which implies it)
/// contribute exactly one.
func linearExtensions<S>(
    _ ops: [Op<S>],
    max: Int,
    repeating: Int = 1,
    seed: UInt64 = SpecDefaults.seed
) -> [[Op<S>]] {
    let multiset = ops.flatMap { operation in
        Array(repeating: operation, count: operation.repeatable ? Swift.max(1, repeating) : 1)
    }
    // One past the cap, so a full enumeration is distinguishable from a truncated one.
    let enumerated = enumerateExtensions(multiset, limit: max + 1)
    guard enumerated.count > max else {
        return enumerated
    }
    return sampleExtensions(multiset, count: max, seed: seed)
}

/// Depth-first enumeration, stopping at `limit`. Exhaustive when it returns fewer than `limit`.
private func enumerateExtensions<S>(_ multiset: [Op<S>], limit: Int) -> [[Op<S>]] {
    var result: [[Op<S>]] = []
    func recurse(_ placed: [Op<S>], _ remaining: [Op<S>]) {
        if result.count >= limit {
            return
        }
        if remaining.isEmpty {
            result.append(placed); return
        }
        let done = Set(placed.map(\.label))
        // One branch per *distinct* next op: two occurrences of the same label are interchangeable,
        // so recursing on both would enumerate the same ordering twice.
        var tried: Set<String> = []
        for (index, operation) in remaining.enumerated() where tried.insert(operation.label).inserted {
            guard operation.afters.allSatisfy(done.contains) else { continue }
            if operation.mustBeLast, remaining.count > 1 {
                continue
            }
            var rest = remaining
            rest.remove(at: index)
            recurse(placed + [operation], rest)
        }
    }
    recurse([], multiset)
    return result
}

/// `count` distinct extensions built by random walks over the available frontier. Attempts are bounded:
/// dedup can starve near the end of a space barely larger than the budget, and returning slightly fewer
/// orderings beats spinning.
private func sampleExtensions<S>(_ multiset: [Op<S>], count: Int, seed: UInt64) -> [[Op<S>]] {
    var rng = SplitMix64(seed: seed)
    var seen = Set<String>()
    var result: [[Op<S>]] = []
    var attempts = 0
    while result.count < count, attempts < count * 20 {
        attempts += 1
        guard let walk = randomExtension(multiset, using: &rng) else {
            break // the partial order admits no ordering at all
        }
        if seen.insert(walk.map(\.label).joined(separator: ">")).inserted {
            result.append(walk)
        }
    }
    return result
}

/// One random linear extension: repeatedly pick among the ops whose constraints are already satisfied.
private func randomExtension<S>(_ multiset: [Op<S>], using rng: inout SplitMix64) -> [Op<S>]? {
    var remaining = multiset
    var placed: [Op<S>] = []
    var done = Set<String>()
    while !remaining.isEmpty {
        var frontier: [Int] = []
        var tried: Set<String> = []
        for (index, operation) in remaining.enumerated() where tried.insert(operation.label).inserted {
            guard operation.afters.allSatisfy(done.contains) else { continue }
            if operation.mustBeLast, remaining.count > 1 {
                continue
            }
            frontier.append(index)
        }
        guard !frontier.isEmpty else {
            return nil
        }
        let index = frontier[Int(rng.next() % UInt64(frontier.count))]
        placed.append(remaining[index])
        done.insert(remaining[index].label)
        remaining.remove(at: index)
    }
    return placed
}

/// How many valid orderings the declared partial order admits, counted without materializing any of
/// them and stopped at `limit` — the space grows factorially, and "≥100000" is as useful a denominator
/// as the true number.
func countLinearExtensions(_ ops: [Op<some Any>], repeating: Int, limit: Int) -> (count: Int, exact: Bool) {
    var counts = ops.map { $0.repeatable ? Swift.max(1, repeating) : 1 }
    let labels = ops.map(\.label)
    let afters = ops.map(\.afters)
    let mustBeLast = ops.map(\.mustBeLast)
    var remaining = counts.reduce(0, +)
    var placed = Set<String>()
    var total = 0
    var stopped = false

    func recurse() {
        if remaining == 0 {
            total += 1
            stopped = total >= limit
            return
        }
        for index in counts.indices where counts[index] > 0 {
            guard afters[index].allSatisfy(placed.contains) else { continue }
            if mustBeLast[index], remaining > 1 {
                continue
            }
            let isFirstOccurrence = placed.insert(labels[index]).inserted
            counts[index] -= 1; remaining -= 1
            recurse()
            counts[index] += 1; remaining += 1
            if isFirstOccurrence {
                placed.remove(labels[index])
            }
            if stopped {
                return
            }
        }
    }
    recurse()
    return (total, !stopped)
}
