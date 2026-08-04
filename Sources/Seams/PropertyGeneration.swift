import Foundation
import HaruspecCore

// Property-based generation at the seam — the *breadth* leg of the harness (SEAMS.md; the "three input
// sources" in ROADMAP.md). A single recorded cassette proves equivalence on ONE path; this generates
// many well-typed seam-value vectors *from that golden cassette as a template* and differentially diffs
// baseline vs candidate across them. The baseline branch is the oracle, so no expected output is needed
// for a generated input.
//
// Generation is the one *commodity* layer (random value production), kept behind the `SeamValueGenerator`
// seam so a richer generator — composable/biased distributions, or an external property-testing library's
// `Gen` — can be swapped in without touching the differential harness or the golden-directed shrinker.
// The bespoke parts (cassette-as-input-surface, differential-diff oracle, golden-directed shrink, and the
// domain-coverage feedback below) are first-party and stay put; the engine has no external dependencies by default.

// MARK: - Generation seam (the swappable commodity layer)

/// Produces seam values for generated cassette variants. Implementations own their own
/// determinism/seeding; `generate` is called once per track position. Returning `recorded` unchanged
/// means "don't vary this seam." Swap in a library-backed conformance to change *how* values are
/// generated without touching `DifferentialProperty`.
public protocol SeamValueGenerator {
    /// The seams this generator varies — the declared *domain surface*, reported into `Coverage`.
    var variedSeams: Set<String> { get }
    /// One reading, at its `position` in that seam's track. A seam read once per op occurrence has as
    /// many positions as the op has occurrences, and "the second add" is a different input from "every
    /// add" — which is what the position lets a generator address.
    mutating func generate(seam: String, at position: Int, like recorded: CanonicalValue) -> CanonicalValue
    /// Called before each variant's track positions, so a generator can make *which* variant this is
    /// mean something — the hook boundary-first generation hangs on. Optional: the default does
    /// nothing, and a purely random generator needs nothing.
    mutating func beginVariant(_ index: Int)
}

public extension SeamValueGenerator {
    mutating func beginVariant(_: Int) {}
}

/// A deterministic PRNG (SplitMix64) so a property run — and any counterexample it finds — is
/// reproducible from a seed. Not a seam: this drives *generation*, not recorded entropy (that's `SeamRNG`).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

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

    func sample(using rng: inout SplitMix64) -> CanonicalValue {
        switch self {
        case let .int(range): .int(Int64.random(in: range, using: &rng))
        case let .double(range): .double(Double.random(in: range, using: &rng))
        case let .anyOf(values):
            // Non-empty by construction via `oneOf`; a hand-built empty set has nothing to vary.
            values.isEmpty ? .null : values[Int(UInt64.random(in: 0 ..< UInt64(values.count), using: &rng))]
        }
    }
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
        }
    }

    private func orderedUnique(_ values: [CanonicalValue]) -> [CanonicalValue] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.canonicalString).inserted }
    }

    /// Vary over a named set. Empty traps at construction rather than silently varying nothing —
    /// a seam declared with no values would report domain coverage it never had.
    static func oneOf(_ values: [String]) -> SeamDomain {
        precondition(!values.isEmpty, "oneOf needs at least one value to vary over")
        return .anyOf(values.map(CanonicalValue.string))
    }

    static func oneOf(_ values: String...) -> SeamDomain {
        oneOf(values)
    }

    static func oneOf(_ values: [Int64]) -> SeamDomain {
        precondition(!values.isEmpty, "oneOf needs at least one value to vary over")
        return .anyOf(values.map(CanonicalValue.int))
    }

    static func oneOf(_ values: Int64...) -> SeamDomain {
        oneOf(values)
    }
}

/// The built-in, dependency-free generator: **boundary values first, then uniform sampling** over a
/// declared per-seam `SeamDomain`, seeded by SplitMix64. A seam with no declared domain replays its
/// recorded value unchanged, so the generated surface is exactly the declared seams. This is the
/// default `SeamValueGenerator`; swapping in a library-backed one is a one-type change.
///
/// The boundary pass is one-factor-at-a-time: each scheduled variant pins *one* seam to *one* of its
/// edges and leaves every other seam on its recorded value, so a divergence names the seam that caused
/// it instead of arriving as a vector of simultaneous extremes. The schedule is round-robin across
/// seams (every seam's first edge before any seam's second), which is what makes a truncated budget
/// still cover every seam.
///
/// "One factor" used to mean one *column*. A seam read once per op occurrence has a whole track of
/// readings, and pinning it flattened all of them — three `add`s in one sequence took the same sku, so
/// mixed baskets survived only in the random tail, and `quantity = 20` meant to say "one line at max"
/// said "every line at max" instead, which can trip a cart-wide cap and report a divergence that has
/// nothing to do with the edge it aimed at. So each edge is now scheduled twice: once across the whole
/// track (the *aggregate* edge — still the case that finds a total overflow) and once at a single
/// reading, with the position rotating so repeated edges sweep different slots. The two spans are
/// interleaved rather than tiered, so a budget too small for the whole schedule still gets both
/// flavors of the seams it reaches — consistent with edges-before-middles, at the cost of a shorter
/// random tail.
public struct DomainSeamGenerator: SeamValueGenerator {
    public var domains: [String: SeamDomain]
    private var rng: SplitMix64
    /// The edges variants claim, in order.
    private let schedule: [Pin]
    /// What this variant pins, or `nil` once the schedule is spent and generation goes random.
    private var pinned: Pin?

    /// One scheduled boundary variant: a seam held at one of its edges, over its whole track or at a
    /// single reading of it.
    private struct Pin {
        let seam: String
        let value: CanonicalValue
        /// `nil` pins every reading (the aggregate edge); a position pins one and leaves the rest golden.
        let position: Int?
    }

    /// `trackLengths` is how many readings each seam's track holds — the golden cassette knows, and the
    /// convenience `generatedVariants(count:varying:seed:)` supplies it. Omitted, every seam is assumed
    /// to be read once and the schedule is exactly the whole-track pass it always was.
    public init(domains: [String: SeamDomain], seed: UInt64, trackLengths: [String: Int] = [:]) {
        self.domains = domains
        rng = SplitMix64(seed: seed)
        schedule = Self.boundarySchedule(domains, trackLengths: trackLengths)
        pinned = schedule.first
    }

    /// Round-robin over sorted seams — sorted so the schedule doesn't ride on dictionary order, which
    /// would make a run's inputs unreproducible across processes.
    private static func boundarySchedule(
        _ domains: [String: SeamDomain],
        trackLengths: [String: Int]
    ) -> [Pin] {
        let edges = domains.keys.sorted().map { (seam: $0, values: domains[$0]?.boundaryValues ?? []) }
        var turns: [String: Int] = [:]
        var schedule: [Pin] = []
        for index in 0 ..< (edges.map(\.values.count).max() ?? 0) {
            for edge in edges where index < edge.values.count {
                schedule.append(Pin(seam: edge.seam, value: edge.values[index], position: nil))
                // A track read once has no distinct single-reading case — `.at(0)` would be the variant
                // above a second time, and a duplicated variant is budget spent on nothing.
                let length = trackLengths[edge.seam] ?? 1
                guard length > 1 else { continue }
                let turn = turns[edge.seam, default: 0]
                turns[edge.seam] = turn + 1
                schedule.append(Pin(seam: edge.seam, value: edge.values[index], position: turn % length))
            }
        }
        return schedule
    }

    public var variedSeams: Set<String> {
        Set(domains.keys)
    }

    public mutating func beginVariant(_ index: Int) {
        pinned = index < schedule.count ? schedule[index] : nil
    }

    public mutating func generate(seam: String, at position: Int, like recorded: CanonicalValue) -> CanonicalValue {
        guard let domain = domains[seam] else { return recorded } // undeclared seam → keep golden
        guard let pinned else { return domain.sample(using: &rng) }
        guard pinned.seam == seam else { return recorded } // one factor at a time
        guard let pinnedPosition = pinned.position else { return pinned.value } // the aggregate edge
        return pinnedPosition == position ? pinned.value : recorded
    }
}

// MARK: - Variant generation from the golden template

public extension CassetteData {
    /// Produce `count` variants of this golden cassette, asking `generator` for each reading. The golden
    /// cassette is the *template* — the seam skeleton (which seams, each arity, each type) is real, only
    /// the values vary — which keeps generation "derived from the real recording," not fabricated.
    func generatedVariants(count: Int, using generator: inout some SeamValueGenerator) -> [CassetteData] {
        var variants: [CassetteData] = []
        variants.reserveCapacity(max(0, count))
        for variant in 0 ..< max(0, count) {
            generator.beginVariant(variant)
            var newTracks = tracks
            for (seam, track) in tracks {
                var newTrack: [CanonicalValue] = []
                newTrack.reserveCapacity(track.count)
                for (position, value) in track.enumerated() {
                    newTrack.append(generator.generate(seam: seam, at: position, like: value))
                }
                newTracks[seam] = newTrack
            }
            variants.append(CassetteData(schemaVersion: schemaVersion, tracks: newTracks))
        }
        return variants
    }

    /// Convenience: variants via the built-in domain generator (dependency-free). The golden's own track
    /// lengths go in, so the boundary pass can pin a single reading of a repeatedly-read seam.
    func generatedVariants(count: Int, varying domains: [String: SeamDomain], seed: UInt64) -> [CassetteData] {
        var generator = DomainSeamGenerator(
            domains: domains,
            seed: seed,
            trackLengths: tracks.mapValues(\.count)
        )
        return generatedVariants(count: count, using: &generator)
    }
}
