import Foundation
import HaruspecCore

// What one seam's readings may be: a declared range or set, or the magnitude ladder the engine
// assumes when nothing was declared. Three views of a domain drive generation (`DomainSeamGenerator`):
// its `boundaryValues` (the edges, pinned one factor at a time), its `interiorValues` (the messy
// middle — what the golden template reads and what the combined variants pair across seams), and its
// `extremes` (the ends every seam is taken to at once).

/// The generation domain for one seam's readings: a numeric range, or a declared set of values.
/// Structured/corpus domains (schema-aware network payloads, recorded-value distributions) are a
/// later refinement.
public enum SeamDomain: Sendable {
    case int(ClosedRange<Int64>)
    case double(ClosedRange<Double>)
    /// Uniform choice from a declared set — the categorical axis, for inputs whose interesting
    /// values are named rather than ranged (a promo code that is sometimes valid, a status string,
    /// an enum's raw values). Prefer the `oneOf` sugar below, which rejects an empty set.
    case anyOf([CanonicalValue])
    /// A decade-stratified span, the domain for a value *nothing* was declared about, where the
    /// interesting magnitudes are unknown and every decade is a hypothesis. Distinct from `.int` on
    /// purpose: an authored range is a declared judgment about which values matter, and it keeps its
    /// author's edge schedule.
    ///
    /// Boundary values ladder the magnitude transitions (`0, ±1, ±9/10/11, ±99/100/101, …`) where
    /// off-by-one and digit-rollover bugs live, and random fill is log-uniform, a decade first and
    /// then a value within it, so small values arrive as often as large ones. Uniform over a wide
    /// span almost never draws the smalls, which is where code actually branches.
    case intMagnitudes(ClosedRange<Int64>)
    /// The floating-point counterpart: decades extend *below* one (`±0.001 …`) because fractional
    /// magnitudes — rates, factors — are where doubles branch.
    case doubleMagnitudes(ClosedRange<Double>)

    /// Draws one reading from the domain.
    ///
    /// - Parameter rng: The generator to draw from, advanced by the draw.
    /// - Returns: A value of the domain's kind, or `.null` for a hand-built empty `.anyOf`, which has
    ///   nothing to vary.
    func sample(using rng: inout SplitMix64) -> CanonicalValue {
        switch self {
        case let .int(range): .int(Int64.random(in: range, using: &rng))
        case let .double(range): .double(Double.random(in: range, using: &rng))
        case let .anyOf(values):
            // Non-empty by construction via `oneOf`; a hand-built empty set has nothing to vary.
            values.isEmpty ? .null : values[Int(UInt64.random(in: 0 ..< UInt64(values.count), using: &rng))]
        case let .intMagnitudes(range):
            .int(Self.logUniform(in: range, using: &rng))
        case let .doubleMagnitudes(range):
            .double(Self.logUniform(in: range, using: &rng))
        }
    }

    /// Returns a log-uniform integer draw: a decade first, with 0–9 as the first decade, then uniform
    /// within it, the sign uniform where the range admits one.
    ///
    /// - Parameters:
    ///   - range: The span to draw within; the draw is clamped into it.
    ///   - rng: The generator to draw from, advanced by the draw.
    /// - Returns: A value in `range`.
    private static func logUniform(in range: ClosedRange<Int64>, using rng: inout SplitMix64) -> Int64 {
        let limit = Swift.max(range.upperBound, -range.lowerBound)
        var decadeFloors: [Int64] = [0]
        var floor: Int64 = 10
        while floor <= limit {
            decadeFloors.append(floor)
            guard floor <= limit / 10 else { break }
            floor *= 10
        }
        let chosen = decadeFloors[Int(UInt64.random(in: 0 ..< UInt64(decadeFloors.count), using: &rng))]
        let ceiling = Swift.min(chosen == 0 ? 9 : chosen * 10 - 1, limit)
        var value = Int64.random(in: chosen ... Swift.max(chosen, ceiling), using: &rng)
        if range.lowerBound < 0, Bool.random(using: &rng) {
            value = -value
        }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    /// Returns a log-uniform double draw between ``smallestDoubleMagnitude`` and the span's largest
    /// magnitude, the sign uniform where the range admits one. Zero arrives via the boundary
    /// schedule, not the fill.
    ///
    /// - Parameters:
    ///   - range: The span to draw within; the draw is clamped into it.
    ///   - rng: The generator to draw from, advanced by the draw.
    /// - Returns: A value in `range`.
    private static func logUniform(in range: ClosedRange<Double>, using rng: inout SplitMix64) -> Double {
        let limit = Swift.max(range.upperBound, -range.lowerBound)
        let exponent = Double.random(
            in: log10(SeamDomain.smallestDoubleMagnitude) ... log10(Swift.max(limit, 1)),
            using: &rng
        )
        var value = pow(10, exponent)
        if range.lowerBound < 0, Bool.random(using: &rng) {
            value = -value
        }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    /// Where the fractional decade ladder bottoms out: per-mille scale, below which differences
    /// stop being distinguishable through the numeric epsilon anyway.
    static let smallestDoubleMagnitude = 0.001
}

public extension SeamDomain {
    /// The values worth trying *first*, in priority order — bugs cluster at the ends of a domain, and
    /// uniform sampling reaches them only by luck: over `.int(0 ... 20)`, 64 draws find a given edge
    /// 95% of the time but 5 draws find it 21% of the time, and a `.double` range never lands on its
    /// bounds at all. Enumerating them makes edge coverage a property of the design rather than of the
    /// budget, so trimming a budget drops random middles instead of the ends.
    ///
    /// A categorical domain is *all* edges: the author named every value because each one is
    /// interesting.
    var boundaryValues: [CanonicalValue] {
        switch self {
        case let .int(range):
            var values: [Int64] = [range.lowerBound, range.upperBound]
            if range.contains(0) {
                values.append(0)
            }
            // One step inside each end: off-by-one lives next to the boundary, not on it.
            values.append(contentsOf: [range.lowerBound + 1, range.upperBound - 1].filter(range.contains))
            return orderedUnique(values.map(CanonicalValue.int))
        case let .double(range):
            var values: [Double] = [range.lowerBound, range.upperBound]
            if range.contains(0) {
                values.append(0)
            }
            return orderedUnique(values.map(CanonicalValue.double))
        case let .anyOf(values):
            return orderedUnique(values)
        case let .intMagnitudes(range):
            // Zero and ±1 first (the guard-clause cluster), then each decade rollover with one step
            // either side, ascending — so a trimmed budget drops the large magnitudes, not the small.
            var ladder: [Int64] = [0, 1, -1]
            var boundary: Int64 = 10
            let limit = Swift.max(range.upperBound, -range.lowerBound)
            while boundary <= limit {
                ladder += [boundary - 1, boundary, boundary + 1]
                ladder += [-(boundary - 1), -boundary, -(boundary + 1)]
                guard boundary <= limit / 10 else { break }
                boundary *= 10
            }
            ladder += [range.lowerBound, range.upperBound]
            return orderedUnique(ladder.filter(range.contains).map(CanonicalValue.int))
        case let .doubleMagnitudes(range):
            // Every power of ten in span, both signs, fractional decades included.
            var ladder: [Double] = [0]
            var magnitude = SeamDomain.smallestDoubleMagnitude
            let limit = Swift.max(range.upperBound, -range.lowerBound)
            while magnitude <= limit {
                ladder += [magnitude, -magnitude]
                magnitude *= 10
            }
            ladder += [range.lowerBound, range.upperBound]
            return orderedUnique(ladder.filter(range.contains).map(CanonicalValue.double))
        }
    }

    private func orderedUnique(_ values: [CanonicalValue]) -> [CanonicalValue] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.canonicalString).inserted }
    }

    /// The values worth trying *together* — the messy middle of a domain, in priority order: what a
    /// typical reading looks like, as opposed to what its edges look like. The first one is what the
    /// golden template reads, so the template sits inside the declared surface rather than at the
    /// degenerate default every edge is then measured against; the rest drive the combined
    /// variants, where every declared seam moves at once.
    ///
    /// A categorical domain's interior is every value: each is as typical as the next, and cycling
    /// them through the combined variants is what pairs a named input with the other seams' middles.
    var interiorValues: [CanonicalValue] {
        let edges = Set(boundaryValues.map(\.canonicalString))
        switch self {
        case let .int(range):
            let span = range.upperBound - range.lowerBound
            let candidates = [range.lowerBound + span / 2, range.lowerBound + span / 4, range.upperBound - span / 4]
            return orderedUnique(candidates.filter(range.contains).map(CanonicalValue.int))
                .filter { !edges.contains($0.canonicalString) }
        case let .double(range):
            let span = range.upperBound - range.lowerBound
            let candidates = [range.lowerBound + span / 2, range.lowerBound + span / 4, range.upperBound - span / 4]
            return orderedUnique(candidates.filter(range.contains).map(CanonicalValue.double))
                .filter { !edges.contains($0.canonicalString) }
        case let .anyOf(values):
            return orderedUnique(values)
        case let .intMagnitudes(range):
            // Mid-decade, ascending — 5, 50, 500 … — positives first, then the negative mirror.
            var middles: [Int64] = []
            var floor: Int64 = 1
            let limit = Swift.max(range.upperBound, -range.lowerBound)
            while floor * 5 <= limit {
                middles.append(floor * 5)
                guard floor <= limit / 10 else { break }
                floor *= 10
            }
            if range.lowerBound < 0 {
                middles += middles.map { -$0 }
            }
            return orderedUnique(middles.filter(range.contains).map(CanonicalValue.int))
        case let .doubleMagnitudes(range):
            // Decades by exponent, so 0.05 is the double nearest 0.05 and not 0.001 × 10 × 5.
            var middles: [Double] = []
            var exponent = log10(SeamDomain.smallestDoubleMagnitude).rounded()
            let limit = Swift.max(range.upperBound, -range.lowerBound)
            while 5 * pow(10, exponent) <= limit {
                middles.append(5 * pow(10, exponent))
                exponent += 1
            }
            if range.lowerBound < 0 {
                middles += middles.map { -$0 }
            }
            return orderedUnique(middles.filter(range.contains).map(CanonicalValue.double))
        }
    }

    /// The two ends of the domain — what "every seam at its low end" and "every seam at its high
    /// end" read, the extremes of the combined pass. A categorical domain's ends are its first and
    /// last named values.
    var extremes: (low: CanonicalValue, high: CanonicalValue) {
        switch self {
        case let .int(range): (.int(range.lowerBound), .int(range.upperBound))
        case let .double(range): (.double(range.lowerBound), .double(range.upperBound))
        case let .anyOf(values): (values.first ?? .null, values.last ?? .null)
        case let .intMagnitudes(range): (.int(range.lowerBound), .int(range.upperBound))
        case let .doubleMagnitudes(range): (.double(range.lowerBound), .double(range.upperBound))
        }
    }

    /// Returns the domain varying over a named set of strings. An empty set traps at construction
    /// rather than silently varying nothing, since a seam declared with no values would report
    /// domain coverage it never had.
    ///
    /// - Parameter values: The strings to choose among; first and last are the domain's ends.
    /// - Returns: An `.anyOf` over `values`, in the order given.
    /// - Precondition: `values` is non-empty.
    static func oneOf(_ values: [String]) -> SeamDomain {
        precondition(!values.isEmpty, "oneOf needs at least one value to vary over")
        return .anyOf(values.map(CanonicalValue.string))
    }

    /// The variadic spelling of the string set, so `.oneOf("SAVE10", "NOPE")` reads as the list it is.
    ///
    /// - Parameter values: The strings to choose among, at least one.
    /// - Returns: An `.anyOf` over `values`, in the order given.
    /// - Precondition: At least one value is given.
    static func oneOf(_ values: String...) -> SeamDomain {
        oneOf(values)
    }

    /// Returns the domain varying over a named set of integers. An empty set traps at construction
    /// rather than silently varying nothing, since a seam declared with no values would report
    /// domain coverage it never had.
    ///
    /// - Parameter values: The integers to choose among; first and last are the domain's ends.
    /// - Returns: An `.anyOf` over `values`, in the order given.
    /// - Precondition: `values` is non-empty.
    static func oneOf(_ values: [Int64]) -> SeamDomain {
        precondition(!values.isEmpty, "oneOf needs at least one value to vary over")
        return .anyOf(values.map(CanonicalValue.int))
    }

    /// The variadic spelling of the integer set, so `.oneOf(0, 1, 99)` reads as the list it is.
    ///
    /// - Parameter values: The integers to choose among, at least one.
    /// - Returns: An `.anyOf` over `values`, in the order given.
    /// - Precondition: At least one value is given.
    static func oneOf(_ values: Int64...) -> SeamDomain {
        oneOf(values)
    }

    /// Both truth values, `false` first — the domain of a flag, such as whether a synthesized
    /// completion block's delivery fails.
    static var bool: SeamDomain {
        .anyOf([.bool(false), .bool(true)])
    }
}
