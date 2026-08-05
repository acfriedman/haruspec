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
    /// How many of `orderingsExplored` deliberately break a declared `.after` precondition — the
    /// defensive stratum. `nil` in artifacts written before the sample was stratified.
    public let outOfOrderExplored: Int?

    public init(
        orderingsExplored: Int,
        orderingsAvailable: Int,
        orderingsAreExact: Bool,
        variantsPerOrdering: Int,
        outOfOrderExplored: Int? = nil
    ) {
        self.orderingsExplored = orderingsExplored
        self.orderingsAvailable = orderingsAvailable
        self.orderingsAreExact = orderingsAreExact
        self.variantsPerOrdering = variantsPerOrdering
        self.outOfOrderExplored = outOfOrderExplored
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

    /// One line for the verdict:
    /// `3200 runs · 50 of 2520 orderings (2%) × 64 seam variants · 12 out-of-order`.
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
        if let outOfOrder = outOfOrderExplored, outOfOrder > 0 {
            text += " · \(outOfOrder) out-of-order"
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
        let available = availableOrderings()

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
                variantsPerOrdering: split.variants,
                outOfOrderExplored: outOfOrderCount(among: orderings.map { $0.map(\.label) })
            ),
            golden: golden,
            domains: seamDomains,
            seed: SpecDefaults.seed
        )
    }
}

extension Spec {
    /// The denominator: how many orderings the declared constraints admit, summed over every shape the
    /// declared multiplicities allow. Counted exactly wherever the memoized state space allows, and
    /// otherwise walked up to a limit and reported as a bound.
    func availableOrderings() -> (count: Int, exact: Bool) {
        guard exploreOrdering else {
            return (1, true)
        }
        let shapes = orderingShapes(operations, repeating: orderingRepeats, limit: SpecDefaults.shapeLimit)
        var total = 0.0
        for shape in shapes.shapes {
            var counter = ExtensionCounter(multiset(operations, shape: shape))
            guard let exact = counter.totalExtensions() else {
                return countLinearExtensions(
                    operations,
                    repeating: orderingRepeats,
                    limit: SpecDefaults.orderingCountLimit
                )
            }
            total += exact
        }
        // 2^53 is where a Double stops representing consecutive integers; past there the count is a
        // display denominator anyway, and the capped walk's honest lower bound is the better answer.
        guard total <= 9_007_199_254_740_992 else {
            return countLinearExtensions(
                operations,
                repeating: orderingRepeats,
                limit: SpecDefaults.orderingCountLimit
            )
        }
        // Sampled shapes make this a floor, not the space: the shapes left out hold orderings too.
        return (Int(total), shapes.exact)
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

/// Enumerate the orderings the declared constraints admit when the space fits in `max`, and *sample*
/// `max` of them when it doesn't.
///
/// Only `.requires` and `.last` bound the space. `.after` is a soft precondition, so the sample is
/// **stratified** instead of filtered: most of the budget goes to orderings that respect every
/// declared precondition, and `SpecDefaults.outOfOrderShare` of it to orderings that break one. That
/// slice is not waste — it is the only way the engine reaches remove-before-add, checkout-on-empty and
/// the rest of the defensive surface, and a differential oracle can't produce a false positive there
/// (there is no expected value to contradict, only "did both branches agree"). Filtering those
/// orderings out is how a spec quietly stops interrogating its own error paths.
///
/// Sampling is the point of the rest. Depth-first truncation returned the first `max` extensions in
/// enumeration order, which all share a long common prefix — the example spec's 50-of-2,520 slice
/// varied only in its tail. A random walk spreads the same budget across the whole space, and weighting
/// each step by `ExtensionCounter` makes that walk *uniform over orderings* (see there for why an
/// unweighted walk isn't). When the state space is too large to count, the walk falls back to unweighted.
///
/// Over a *multiset* of ops: an op contributes as many occurrences as `.repeating(_:)` declares — or as
/// `Ordering(repeating:)` does where it doesn't — so orderings explore applying an operation more than
/// once, which is where merge-into-existing and remove-what-is-not-there branches live. An op that
/// declares a *range* contributes a count that varies between sequences, which puts the whole multiset
/// on the sampled axis rather than fixing it (see `Multiplicity.swift`).
func linearExtensions<S>(
    _ ops: [Op<S>],
    max: Int,
    repeating: Int = 1,
    seed: UInt64 = SpecDefaults.seed
) -> [[Op<S>]] {
    let shapes = orderingShapes(ops, repeating: repeating, limit: SpecDefaults.shapeLimit, seed: seed).shapes
    guard let single = shapes.first, shapes.count == 1 else {
        return extensionsAcross(shapes, ops: ops, max: max, seed: seed)
    }
    return extensions(of: single, ops: ops, max: max, seed: seed)
}

/// The sample within one fixed multiset: exhaustive when the space fits, stratified around the soft
/// preconditions when it doesn't.
private func extensions<S>(of shape: OrderingShape, ops: [Op<S>], max: Int, seed: UInt64) -> [[Op<S>]] {
    let admitted = multiset(ops, shape: shape)
    // One past the cap, so a full enumeration is distinguishable from a truncated one. An exhaustive
    // space needs no strata — it already holds every in-order and out-of-order sequence.
    let enumerated = enumerateExtensions(admitted, limit: max + 1)
    guard enumerated.count > max else {
        return enumerated
    }

    let preconditions = preconditions(of: ops)
    let inOrder = multiset(gated(ops, strict: true), shape: shape)
    let quota = preconditions.isEmpty ? 0 : Int((Double(max) * SpecDefaults.outOfOrderShare).rounded())

    var sample = sampleExtensions(inOrder, count: max - quota, seed: seed)
    var seen = Set(sample.map { orderingKey($0) })
    // Rejection sampling over the same admitted space: cheaper than enumerating the violating region,
    // and it stays uniform within the stratum.
    let outOfOrder = sampleExtensions(admitted, count: max - sample.count, seed: seed &+ 1, excluding: seen) {
        !violatedPreconditions(in: $0.map(\.label), declaredBy: preconditions).isEmpty
    }
    sample += outOfOrder
    // A stratum too thin to fill its quota hands the remainder back rather than shrinking the sweep.
    if sample.count < max {
        seen.formUnion(outOfOrder.map { orderingKey($0) })
        sample += sampleExtensions(inOrder, count: max - sample.count, seed: seed &+ 2, excluding: seen)
    }
    return sample
}

/// The ops as one exploration stratum enforces them. `strict` folds the soft `.after` preconditions
/// into the hard gates, which is how the in-order stratum is built; the out-of-order stratum walks the
/// declared gates alone and filters for violations afterwards.
func gated<S>(_ ops: [Op<S>], strict: Bool) -> [Op<S>] {
    guard strict else {
        return ops
    }
    return ops.map { operation in
        var copy = operation; copy.gates += operation.afters; return copy
    }
}

/// Orderings are identified by their label sequence: two occurrences of one label are interchangeable.
func orderingKey(_ order: [Op<some Any>]) -> String {
    order.map(\.label).joined(separator: ">")
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
            guard operation.gates.allSatisfy(done.contains) else { continue }
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

/// `count` distinct extensions built by random walks, skipping anything already in `excluding` or
/// rejected by `keeping` (how the out-of-order stratum is drawn). Attempts are bounded: dedup can
/// starve near the end of a space barely larger than the budget — and a rejection filter can starve
/// outright — and returning slightly fewer orderings beats spinning.
func sampleExtensions<S>(
    _ multiset: [Op<S>],
    count: Int,
    seed: UInt64,
    excluding taken: Set<String> = [],
    keeping include: ([Op<S>]) -> Bool = { _ in true }
) -> [[Op<S>]] {
    guard count > 0 else {
        return []
    }
    var rng = SplitMix64(seed: seed)
    var counter = ExtensionCounter(multiset)
    var seen = taken
    var result: [[Op<S>]] = []
    var attempts = 0
    while result.count < count, attempts < count * 20 {
        attempts += 1
        guard let walk = randomExtension(multiset, using: &rng, weightedBy: &counter) else {
            break // the partial order admits no ordering at all
        }
        guard include(walk), seen.insert(orderingKey(walk)).inserted else { continue }
        result.append(walk)
    }
    return result
}

/// One random linear extension: repeatedly pick among the ops whose constraints are already satisfied,
/// in proportion to how many complete orderings lie beneath each choice.
private func randomExtension<S>(
    _ multiset: [Op<S>],
    using rng: inout SplitMix64,
    weightedBy counter: inout ExtensionCounter
) -> [Op<S>]? {
    var remaining = multiset
    var placed: [Op<S>] = []
    var done = Set<String>()
    while !remaining.isEmpty {
        var frontier: [Int] = []
        var tried: Set<String> = []
        for (index, operation) in remaining.enumerated() where tried.insert(operation.label).inserted {
            guard operation.gates.allSatisfy(done.contains) else { continue }
            if operation.mustBeLast, remaining.count > 1 {
                continue
            }
            frontier.append(index)
        }
        guard !frontier.isEmpty else {
            return nil
        }
        let index = frontier[counter.choose(from: frontier.map { remaining[$0].label }, using: &rng)]
        counter.take(remaining[index].label)
        placed.append(remaining[index])
        done.insert(remaining[index].label)
        remaining.remove(at: index)
    }
    counter.reset()
    return placed
}

/// How many valid orderings the declared partial order admits, counted without materializing any of
/// them and stopped at `limit` — the space grows factorially, and "≥100000" is as useful a denominator
/// as the true number.
func countLinearExtensions(_ ops: [Op<some Any>], repeating: Int, limit: Int) -> (count: Int, exact: Bool) {
    let shapes = orderingShapes(ops, repeating: repeating, limit: SpecDefaults.shapeLimit)
    var total = 0
    var exact = shapes.exact
    for shape in shapes.shapes {
        let counted = countExtensions(ops, shape: shape, limit: limit - total)
        total += counted.count
        exact = exact && counted.exact
        if total >= limit {
            return (total, false)
        }
    }
    return (total, exact)
}

/// The walk for one shape, stopped at `limit`.
private func countExtensions(_ ops: [Op<some Any>], shape: OrderingShape, limit: Int) -> (count: Int, exact: Bool) {
    var counts = shape
    let labels = ops.map(\.label)
    let gates = ops.map(\.gates)
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
            guard gates[index].allSatisfy(placed.contains) else { continue }
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
