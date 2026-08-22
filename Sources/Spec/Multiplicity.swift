import Foundation
import HaruspecSeams

// How many times each op appears in a sequence — the axis `Ordering(repeating:)` used to own alone.
//
// That number was spec-wide, which stopped fitting the moment ops were collapsed: one `add` wants
// applying six times where one `applyPromo` wants two, and the only lever was a global dial that buys
// both. Sequence length is the cost model's one super-linear term, so length you didn't want is the
// expensive kind of waste. `.repeating(_:)` makes the count per-op.
//
// A *range* is the other half, and it is not the same feature. Exact multiplicity — every op appearing
// the same number of times in every sequence — means the reachable state space has a floor: no sampled
// ordering can check out an empty cart, hold a single-line cart, or run without the promo ever firing,
// because every sequence runs every op. Sampling more orderings never fixes that; only varying the
// counts does. The sequences a range adds are shorter than the ones already being run, so the axis it
// opens is cheaper per run than the one it extends.

/// How many times each op appears, aligned with the op list it was derived from. One shape is the
/// exact-multiplicity case — every op a fixed count — and stays the fast path everywhere below.
typealias OrderingShape = [Int]

extension Op {
    /// The occurrence range this op admits, resolving an undeclared one against `Ordering(repeating:)`.
    func occurrences(default repeats: Int) -> ClosedRange<Int> {
        guard let multiplicity else {
            let exact = Swift.max(1, repeats)
            return exact ... exact
        }
        return multiplicity
    }
}

/// Every shape the declared ranges admit, or `limit` of them sampled when the product is larger than
/// that. `exact` is false in the sampled case, which is what stops a denominator built from these from
/// claiming to be the whole space.
///
/// Shapes that place no ops at all are dropped: an empty sequence produces an empty trace on both
/// branches, so it is a run that cannot say anything.
func orderingShapes(
    _ ops: [Op<some Any>],
    repeating: Int,
    limit: Int,
    seed: UInt64 = SpecDefaults.seed
) -> (shapes: [OrderingShape], exact: Bool) {
    let ranges = ops.map { $0.occurrences(default: repeating) }
    let total = ranges.reduce(1) { $0 * $1.count }

    guard total > limit else {
        var shapes: [OrderingShape] = [[]]
        for range in ranges {
            shapes = shapes.flatMap { shape in range.map { shape + [$0] } }
        }
        return (shapes.filter { $0.contains { $0 > 0 } }, true)
    }

    // Too many to enumerate: draw shapes instead. Sampling the *count* vector is the same kind of
    // concession the ordering walk already makes, and it keeps one code path downstream.
    var rng = SplitMix64(seed: seed)
    var drawn: [OrderingShape] = []
    var seen = Set<String>()
    var attempts = 0
    while drawn.count < limit, attempts < limit * 4 {
        attempts += 1
        let shape = ranges.map { range in
            range.lowerBound + Int(rng.next() % UInt64(range.count))
        }
        guard shape.contains(where: { $0 > 0 }), seen.insert(shape.map(String.init).joined(separator: ",")).inserted
        else { continue }
        drawn.append(shape)
    }
    return (drawn, false)
}

/// The multiset one shape describes: `shape[i]` copies of `ops[i]`.
func multiset<S>(_ ops: [Op<S>], shape: OrderingShape) -> [Op<S>] {
    zip(ops, shape).flatMap { operation, count in Array(repeating: operation, count: count) }
}

/// Spread the budget *across* shapes rather than over the union of their orderings.
///
/// Uniform-over-orderings would hand the largest shape nearly the whole sample — on the cart spec's
/// numbers the maximal multiset alone holds about a third of the 110,251 orderings, and the long tail
/// of short shapes holds a few each. But the short sequences are the entire reason a range was declared:
/// they are what reaches an empty-cart checkout, and they are cheaper to run than the long ones. So
/// every shape gets a draw before any shape gets a second.
func extensionsAcross<S>(_ shapes: [OrderingShape], ops: [Op<S>], max: Int, seed: UInt64) -> [[Op<S>]] {
    guard !shapes.isEmpty else {
        return []
    }
    var rng = SplitMix64(seed: seed)
    var visiting = Array(shapes.indices)
    visiting.shuffle(using: &rng) // deterministic, but not the odometer order shapes were built in

    var sampler = ShapeSampler(ops: ops)
    // Bounded passes: a shape holding one ordering gives it up on the first visit and nothing after.
    for pass in 0 ..< SpecDefaults.shapePasses where sampler.sample.count < max {
        for index in visiting where sampler.sample.count < max {
            sampler.take(from: shapes[index], seed: seed &+ UInt64(index) &+ UInt64(pass) &* 0x9E37_79B9)
        }
    }
    return sampler.sample
}

/// Draws one ordering at a time from whichever shape it is handed, holding the out-of-order stratum to
/// its share across the *whole* sample rather than within each shape — a short shape may admit no
/// violating ordering at all, so a per-shape quota would go unfilled and under-report the stratum.
private struct ShapeSampler<S> {
    private let ops: [Op<S>]
    private let strict: [Op<S>]
    private let declared: [String: [String]]
    private var seen = Set<String>()
    private var outOfOrder = 0
    private(set) var sample: [[Op<S>]] = []

    init(ops: [Op<S>]) {
        self.ops = ops
        strict = gated(ops, strict: true)
        declared = preconditions(of: ops)
    }

    mutating func take(from shape: OrderingShape, seed: UInt64) {
        let wanted = !declared.isEmpty
            && Double(outOfOrder) < SpecDefaults.outOfOrderShare * Double(sample.count + 1)
        guard let drawn = draw(shape, violating: wanted, seed: seed)
            ?? draw(shape, violating: !wanted, seed: seed &+ 1)
        else { return }
        seen.insert(orderingKey(drawn))
        if !violatedPreconditions(in: drawn.map(\.label), declaredBy: declared).isEmpty {
            outOfOrder += 1
        }
        sample.append(drawn)
    }

    private func draw(_ shape: OrderingShape, violating: Bool, seed: UInt64) -> [Op<S>]? {
        guard violating else {
            return sampleExtensions(multiset(strict, shape: shape), count: 1, seed: seed, excluding: seen).first
        }
        return sampleExtensions(multiset(ops, shape: shape), count: 1, seed: seed, excluding: seen) {
            !violatedPreconditions(in: $0.map(\.label), declaredBy: declared).isEmpty
        }.first
    }
}
