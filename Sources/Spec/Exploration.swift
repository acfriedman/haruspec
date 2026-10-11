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
    /// defensive stratum.
    public let outOfOrderExplored: Int
    /// Boundary-edge variants the declared seam domains schedule against the golden template — the
    /// edges-before-middles pass (`DomainSeamGenerator`). Zero when no declared domain matched a
    /// recorded seam: there was no boundary schedule to spend on.
    public let boundaryEdgesScheduled: Int
    /// How many scheduled edges the variant budget actually ran. The remainder is dropped when
    /// `variantsPerOrdering` runs out — and reported: a sweep that skipped 11 of its 38 edges should
    /// say so rather than read as edge-complete.
    public let boundaryEdgesCovered: Int
    /// Variants per ordering that moved every declared seam at once — the all-edges vectors, the
    /// interior rungs, and the uniform samples that share the budget with the edge pins. Zero means
    /// no probe ever paired two seams' values, which is the honest thing to say about a sweep that
    /// spent its whole budget one factor at a time.
    public let combinedVariantsCovered: Int
    /// The settle schedules the budget bought each ordering (see `SettlePoints.swift`): 1 when the
    /// subject never held work across a gap, so settle points had nothing to land.
    public let settleSchedulesPerOrdering: Int
    /// Orderings run once per settle schedule: `orderingsExplored` when settle points are off, fewer
    /// than `orderingsExplored × settleSchedulesPerOrdering` when short orderings ran out of gaps.
    public let settledOrderingsExplored: Int

    public init(
        orderingsExplored: Int,
        orderingsAvailable: Int,
        orderingsAreExact: Bool,
        variantsPerOrdering: Int,
        outOfOrderExplored: Int,
        boundaryEdgesScheduled: Int,
        boundaryEdgesCovered: Int,
        combinedVariantsCovered: Int,
        settleSchedulesPerOrdering: Int = 1,
        settledOrderingsExplored: Int? = nil
    ) {
        self.orderingsExplored = orderingsExplored
        self.orderingsAvailable = orderingsAvailable
        self.orderingsAreExact = orderingsAreExact
        self.variantsPerOrdering = variantsPerOrdering
        self.outOfOrderExplored = outOfOrderExplored
        self.boundaryEdgesScheduled = boundaryEdgesScheduled
        self.boundaryEdgesCovered = boundaryEdgesCovered
        self.combinedVariantsCovered = combinedVariantsCovered
        self.settleSchedulesPerOrdering = settleSchedulesPerOrdering
        self.settledOrderingsExplored = settledOrderingsExplored ?? orderingsExplored
    }

    /// Differential runs spent: each drives the baseline and the candidate once.
    public var runs: Int {
        settledOrderingsExplored * variantsPerOrdering
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
    /// `3200 runs · 50 of 2520 orderings (2%) × 4 settle schedules × 16 seam variants · 12 out-of-order`.
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
        if settleSchedulesPerOrdering > 1 {
            // Short orderings have fewer gaps, so fewer schedules than the budget offered them.
            let every = settledOrderingsExplored >= orderingsExplored * settleSchedulesPerOrdering
            text += " × \(every ? "" : "up to ")\(settleSchedulesPerOrdering) settle schedules"
        }
        if variantsPerOrdering > 1 {
            text += " × \(variantsPerOrdering) seam variants"
        }
        if outOfOrderExplored > 0 {
            text += " · \(outOfOrderExplored) out-of-order"
        }
        return text
    }

    /// Rounded, except that a non-zero share never renders as `0%` — "we covered none of it" and
    /// "we covered a sliver" are different findings. Internal: the qualification block renders its
    /// ordering fraction with the same rule, so the two lines can't disagree about a sliver.
    static func percent(_ fraction: Double) -> String {
        let rounded = Int((fraction * 100).rounded())
        return rounded == 0 ? "<1%" : "\(rounded)%"
    }
}

/// The generation constants shared by the live differential and the recorded plan — one surface,
/// whichever side of a build boundary it runs on.
enum SpecDefaults {
    static let seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    /// Seam cassettes per ordering when no `Budget(runs:)` is declared.
    static let variantCount = 64
    /// Where counting valid orderings gives up and reports a lower bound. A denominator is worth a few
    /// milliseconds, not a factorial walk.
    static let orderingCountLimit = 100_000
    /// The share of a sampled ordering budget spent on sequences that break a declared `.after`
    /// precondition. A quarter is enough that every declared precondition is broken several times over
    /// at a typical `Ordering(max: 50)`, while the bulk of the sweep stays on the surface the author
    /// described. Zero when a spec declares no preconditions — there is no such stratum to draw from.
    static let outOfOrderShare = 0.25
    /// How many distinct occurrence-count shapes a spec's declared `.repeating(_:)` ranges may produce
    /// before shapes are sampled rather than enumerated. Generous: the product only grows when an author
    /// declares several ranged ops, and the fallback is a lower-bound denominator, not a wrong one.
    static let shapeLimit = 4096
    /// How many times the sampler revisits every shape. Each pass draws at most one ordering per shape,
    /// so this bounds the work when most shapes are exhausted and the budget still isn't spent.
    static let shapePasses = 8
    /// The span a derived integer argument fuzzes over (`SeamDomain.intMagnitudes`): four decades,
    /// both signs — nothing was declared about the value, so every magnitude is a hypothesis and
    /// negatives are probes like any other (a divergence on `-1` is a finding, not noise). Narrow
    /// widths get the span their type can represent: the emitted conversions trap on overflow, so
    /// the domain must never claim a value the parameter cannot take.
    static let derivedIntSpan: ClosedRange<Int64> = -10000 ... 10000
    /// `Int8`-safe (±127) and `UInt8`-safe (0–255) clips of the same ladder.
    static let derivedTinyIntSpan: ClosedRange<Int64> = -100 ... 100
    static let derivedUnsignedSpan: ClosedRange<Int64> = 0 ... 10000
    static let derivedUnsignedTinySpan: ClosedRange<Int64> = 0 ... 100
    /// The derived `Double` span (`SeamDomain.doubleMagnitudes`): decades from per-mille to a
    /// thousand, both signs — fractional magnitudes included because rates and factors live there.
    static let derivedDoubleSpan: ClosedRange<Double> = -1000 ... 1000
    /// Exploration defaults a derived spec runs at when `.vary` declares nothing: ordering variation
    /// on (it is half the point of deriving a surface) at a bounded sample, and a budget that keeps
    /// an unconfigured spec's cost predictable. `.vary` overrides either.
    static let derivedOrderingMax = 50
    static let derivedBudget = 1200
    /// How many times a derived op appears per sequence. A *range from zero*, because absence is what
    /// reaches the states a fixed count never does (a checkout on an empty cart) — the same reasoning
    /// as `.repeating(0 ... n)`, applied as the default rather than the exception.
    static let derivedRepetition: ClosedRange<Int> = 0 ... 3
    /// Settle schedules per ordering when no `Budget(runs:)` is declared and the subject holds work
    /// across a gap: both corners and the first two single flips
    /// (``SettleSchedules/sample(gaps:max:seed:)``).
    static let settleSchedules = 4
}

// MARK: - The resolved plan

/// The exact work one verify or record will do: which orderings, and how the seam budget is spent
/// against each. Shared by ``BaselinedSpec/verify(candidate:declaring:)`` and ``BaselinedSpec/record()`` so
/// the live differential and the recorded plan explore the same surface by construction rather than
/// by two copies of the same loop.
struct ExplorationPlan<S> {
    /// The declared operations of each ordering, without settle steps: the ordering axis.
    let orderings: [[Op<S>]]
    /// The most settle schedules any one ordering runs under; 1 when settle points are off.
    let settleSchedulesPerOrdering: Int
    let variantsPerOrdering: Int
    let exploration: Exploration
    private let golden: CassetteData
    /// Declared domains plus the resource sweeps the golden earned — the varied surface the plan
    /// actually explores, which is why callers read it rather than `Spec.seamDomains`.
    let domains: [String: SeamDomain]
    private let seed: UInt64

    init(
        orderings: [[Op<S>]],
        settleSchedulesPerOrdering: Int,
        variantsPerOrdering: Int,
        exploration: Exploration,
        golden: CassetteData,
        domains: [String: SeamDomain],
        seed: UInt64
    ) {
        self.orderings = orderings
        self.settleSchedulesPerOrdering = settleSchedulesPerOrdering
        self.variantsPerOrdering = variantsPerOrdering
        self.exploration = exploration
        self.golden = golden
        self.domains = domains
        self.seed = seed
    }

    /// Every run the plan makes, in sweep order: each ordering under each of its settle schedules,
    /// against each of the ordering's cassettes.
    ///
    /// - Returns: One entry per differential run; the schedules of one ordering share its cassettes,
    ///   so a schedule is all that differs between those runs.
    func runs() -> [(order: [Op<S>], cassette: CassetteData)] {
        orderings.indices.flatMap { index in
            let cassettes = cassettes(forOrdering: index)
            return settledOrders(forOrdering: index).flatMap { order in
                cassettes.map { (order: order, cassette: $0) }
            }
        }
    }

    /// Ordering `index` under each settle schedule it runs, the all-held one first.
    ///
    /// - Parameter index: The ordering's place in ``orderings``.
    /// - Returns: The orderings a capture drives, settle steps interleaved.
    func settledOrders(forOrdering index: Int) -> [[Op<S>]] {
        let order = orderings[index]
        return SettleSchedules.sample(
            gaps: Swift.max(0, order.count - 1),
            max: settleSchedulesPerOrdering,
            seed: seed &+ UInt64(index)
        )
        .map { interleaving($0, into: order) }
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
    /// Resolves what this spec declared into the work a run will actually do — plus the packaged
    /// sweeps the golden's reach earned (`resourceSweeps`), which join the declared surface here.
    ///
    /// - Parameters:
    ///   - golden: The golden template's seam readings.
    ///   - heldWorkAtGaps: Whether the golden capture held work across a gap. Only then do settle
    ///     schedules buy anything, so only then do they take a share of the budget.
    /// - Returns: The plan both sides of a run explore.
    func explorationPlan(golden: CassetteData, heldWorkAtGaps: Bool) -> ExplorationPlan<S> {
        let seamDomains = seamDomains.merging(resourceSweeps(reaching: golden.tracks.keys)) { declared, _ in declared }
        // Against what the golden actually recorded, not what was declared: a domain whose key nothing
        // reads moves nothing, and buying it a seam axis spends the budget generating identical
        // cassettes while the verdict reports them as variants.
        let hasSeams = !Set(seamDomains.keys).isDisjoint(with: golden.tracks.keys)
        let available = availableOrderings()

        // Resolve the budget *before* enumerating: taking a prefix of an exhaustive enumeration would
        // reintroduce exactly the prefix bias the sampling below exists to remove.
        // Against what the ordering axis can *actually* supply, not the declared cap: a spec whose
        // partial order admits 2 orderings would otherwise spend a 200-run budget on 22 runs.
        let split = ExplorationBudget.split(
            orderingCap: exploreOrdering ? Swift.min(maxOrderings, available.count) : 1,
            scheduleCap: heldWorkAtGaps ? SpecDefaults.settleSchedules : 1,
            variants: hasSeams ? SpecDefaults.variantCount : 1,
            budget: explorationBudget
        )
        let orderings = exploreOrdering
            ? linearExtensions(operations, max: split.orderings, repeating: orderingRepeats)
            : [operations]
        let settledOrderings = orderings.reduce(0) { total, order in
            total + Swift.min(split.schedules, SettleSchedules.spaceSize(gaps: Swift.max(0, order.count - 1)))
        }

        // The schedule is deterministic from (domains × golden tracks), so its shape is knowable
        // here without running generation — and recomputable at replay from the plan's golden probe.
        let generator = hasSeams
            ? DomainSeamGenerator(domains: seamDomains, seed: SpecDefaults.seed, golden: golden.tracks)
            : nil

        return ExplorationPlan(
            orderings: orderings,
            settleSchedulesPerOrdering: split.schedules,
            variantsPerOrdering: split.variants,
            exploration: Exploration(
                orderingsExplored: orderings.count,
                orderingsAvailable: Swift.max(available.count, orderings.count),
                orderingsAreExact: available.exact,
                variantsPerOrdering: split.variants,
                outOfOrderExplored: outOfOrderCount(among: orderings.map { $0.map(\.label) }),
                boundaryEdgesScheduled: generator?.scheduledBoundaryEdges ?? 0,
                boundaryEdgesCovered: generator?.boundaryEdgesCovered(within: split.variants) ?? 0,
                combinedVariantsCovered: generator?.combinedVariantsCovered(within: split.variants) ?? 0,
                settleSchedulesPerOrdering: split.schedules,
                settledOrderingsExplored: settledOrderings
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

/// Splitting a declared run budget across the axes.
enum ExplorationBudget {
    /// Splits the budget three ways when the subject holds work across a gap, and two ways otherwise.
    ///
    /// - Parameters:
    ///   - orderingCap: The most orderings the declaration admits.
    ///   - scheduleCap: The settle schedules each ordering would get unbounded; 1 when settle
    ///     points are off.
    ///   - variants: The seam variants each run would get unbounded; 1 with no seam axis.
    ///   - budget: The declared `Budget(runs:)`, if any.
    /// - Returns: Orderings, settle schedules per ordering, and seam variants per settled ordering.
    ///
    /// Every ordering runs under the same settle schedules, so the schedule axis is split as part
    /// of the ordering one (orderings × schedules, against seam variants), then taken back out at
    /// the ordering axis's aspect ratio. It never drops below the two corners while the budget
    /// buys two runs: the all-held corner is the capture as it ran before settle points, and the
    /// all-elapsed corner is the one a second schedule exists for.
    static func split(orderingCap: Int, scheduleCap: Int, variants: Int, budget: Int?) -> Split {
        let schedules = Swift.max(1, scheduleCap)
        let orderings = Swift.max(1, orderingCap)
        guard schedules > 1 else {
            let twoWay = Self.split(orderingCap: orderings, variants: variants, budget: budget)
            return Split(orderings: twoWay.orderings, schedules: 1, variants: twoWay.variants)
        }
        let combined = Self.split(orderingCap: orderings * schedules, variants: variants, budget: budget)
        let pairs = combined.orderings
        guard pairs < orderings * schedules else {
            return Split(orderings: orderings, schedules: schedules, variants: combined.variants)
        }
        let scale = (Double(pairs) / Double(orderings * schedules)).squareRoot()
        let corners = Swift.min(2, pairs)
        let perOrdering = Swift.min(schedules, Swift.max(corners, Int((Double(schedules) * scale).rounded())))
        let orderingCount = Swift.min(orderings, Swift.max(1, pairs / perOrdering))
        let variantCount = variants > 1 ? Swift.max(1, (budget ?? pairs) / (orderingCount * perOrdering)) : 1
        return Split(orderings: orderingCount, schedules: perOrdering, variants: variantCount)
    }

    /// What one run's budget buys on each axis.
    struct Split: Equatable {
        /// Orderings explored.
        let orderings: Int
        /// Settle schedules each ordering runs under.
        let schedules: Int
        /// Seam variants each settled ordering runs against.
        let variants: Int
    }

    /// Shrinks both axes by the same factor rather than draining one to fill the other: the two find
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
/// Sampling is the point of the rest. Depth-first truncation would return the first `max` extensions in
/// enumeration order, which all share a long common prefix — the example spec's 50-of-2,520 slice would
/// vary only in its tail. A random walk spreads the same budget across the whole space, and weighting
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
