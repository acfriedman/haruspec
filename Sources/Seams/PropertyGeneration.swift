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

/// The built-in, dependency-free generator: **edges and middles interleaved, then uniform sampling**
/// over a declared per-seam `SeamDomain`, seeded by SplitMix64. A seam with no declared domain replays
/// its recorded value unchanged, so the generated surface is exactly the declared seams. This is the
/// default `SeamValueGenerator`; swapping in a library-backed one is a one-type change.
///
/// Two streams share the variant budget, alternating from the first variant, so any prefix of the
/// schedule holds both kinds:
///
///  - **Edge pins**, one factor at a time: each pins *one* seam to *one* of its edges and leaves every
///    other seam on its recorded value, so a divergence names the seam that caused it instead of
///    arriving as a vector of simultaneous extremes. Round-robin across seams (every seam's first
///    edge before any seam's second), which is what makes a truncated budget still cover every seam.
///  - **Combined variants**, every declared seam at once: first every seam at its low end, then every
///    seam at its high end, then the messy middle — each seam at one of its interior values, cycling
///    a categorical seam through its names — and, once those are spent, uniform samples. This is the
///    only place two seams' values meet, which a tiered schedule (all edges, *then* a random tail)
///    never reached once the edge schedule alone outgrew the budget.
///
/// A "factor" is finer than a column: a seam read once per op occurrence has a whole track of
/// readings, and pinning the whole track flattens it — three `add`s in one sequence take the same sku,
/// so mixed baskets survive only in the random tail, and `quantity = 20` meant to say "one line at max"
/// says "every line at max" instead, which can trip a cart-wide cap and report a divergence that has
/// nothing to do with the edge it aimed at. So each edge is scheduled twice: once across the whole
/// track (the *aggregate* edge — still the case that finds a total overflow) and once at a single
/// reading, with the position rotating so repeated edges sweep different slots. The two spans are
/// interleaved rather than tiered, so a budget too small for the whole schedule still gets both
/// flavors of the seams it reaches.
public struct DomainSeamGenerator: SeamValueGenerator {
    public var domains: [String: SeamDomain]
    private var rng: SplitMix64
    /// The edge pins variants claim, in order — the one-factor stream.
    private let edges: [Pin]
    /// The finite head of the combined stream; past it, combined variants are uniform samples.
    private let combined: [Combined]
    /// What this variant is.
    private var slot: Slot = .random

    /// One scheduled boundary variant: a seam held at one of its edges, over its whole track or at a
    /// single reading of it.
    private struct Pin {
        let seam: String
        let value: CanonicalValue
        /// `nil` pins every reading (the aggregate edge); a position pins one and leaves the rest golden.
        let position: Int?
    }

    /// One scheduled combined variant — every declared seam moved at once.
    private enum Combined {
        case lowEdges
        case highEdges
        /// Every seam at its `interiorValues[index % count]`.
        case interior(Int)
    }

    private enum Slot {
        case edge(Pin)
        case combined(Combined)
        case random
    }

    /// `golden` is the template's own tracks — the convenience `generatedVariants(count:varying:seed:)`
    /// supplies them. They give the schedule two things it cannot otherwise know: how many readings each
    /// seam has, and what each already holds. Omitted, every seam is assumed to be read once and the
    /// edge schedule is exactly the whole-track pass it always was.
    public init(domains: [String: SeamDomain], seed: UInt64, golden: [String: [CanonicalValue]] = [:]) {
        self.domains = domains
        rng = SplitMix64(seed: seed)
        edges = Self.boundarySchedule(domains, golden: golden)
        combined = Self.combinedSchedule(domains, golden: golden)
        slot = Self.slot(forVariant: 0, edges: edges, combined: combined)
    }

    /// Round-robin over sorted seams — sorted so the schedule doesn't ride on dictionary order, which
    /// would make a run's inputs unreproducible across processes.
    private static func boundarySchedule(
        _ domains: [String: SeamDomain],
        golden: [String: [CanonicalValue]]
    ) -> [Pin] {
        let perSeam = domains.keys.sorted().map { seam in
            pins(seam: seam, edges: domains[seam]?.boundaryValues ?? [], track: golden[seam] ?? [])
        }
        var schedule: [Pin] = []
        for index in 0 ..< (perSeam.map(\.count).max() ?? 0) {
            for seam in perSeam where index < seam.count {
                schedule.append(seam[index])
            }
        }
        return schedule
    }

    /// The combined stream's finite head: the two all-edges vectors, then one interior vector per
    /// interior rung of the widest domain. A vector the golden already holds is dropped (it would
    /// replay the golden itself), and with a single declared seam the all-edges vectors are its own
    /// aggregate pins again, so only the true middles are kept.
    private static func combinedSchedule(
        _ domains: [String: SeamDomain],
        golden: [String: [CanonicalValue]]
    ) -> [Combined] {
        guard !domains.isEmpty else {
            return []
        }
        func heldByGolden(_ value: (SeamDomain) -> CanonicalValue) -> Bool {
            domains.allSatisfy { seam, domain in
                let track = golden[seam] ?? []
                return !track.isEmpty && track.allSatisfy { $0.canonicalString == value(domain).canonicalString }
            }
        }
        var schedule: [Combined] = []
        if domains.count > 1 {
            if !heldByGolden({ $0.extremes.low }) {
                schedule.append(.lowEdges)
            }
            if !heldByGolden({ $0.extremes.high }) {
                schedule.append(.highEdges)
            }
        }
        let rungs = domains.values.map(\.interiorValues.count).max() ?? 0
        for index in 0 ..< rungs {
            let single = domains.count == 1 ? domains.values.first : nil
            // One seam: an interior value that is also an edge is a scheduled pin already.
            if let single, let value = single.interior(at: index),
               single.boundaryValues.contains(where: { $0.canonicalString == value.canonicalString }) {
                continue
            }
            if !heldByGolden({ $0.interior(at: index) ?? .null }) {
                schedule.append(.interior(index))
            }
        }
        return schedule
    }

    /// One seam's entries: its edges across the whole track, interleaved with its edges at a single
    /// reading.
    ///
    /// - Parameters:
    ///   - seam: The seam key every produced `Pin` targets.
    ///   - edges: The domain's edge values for this seam, in schedule order.
    ///   - track: The golden cassette's readings for this seam, in reading order; empty when the
    ///     golden never read it.
    /// - Returns: Whole-track pins and single-reading pins interleaved, so a truncated budget still
    ///   gets both flavors. Duplicates of the golden are dropped: an edge the track already holds at
    ///   every pinned position replays as the golden itself, and a track read once has no distinct
    ///   single-reading case (a position-0 pin is the whole-track pin again).
    private static func pins(seam: String, edges: [CanonicalValue], track: [CanonicalValue]) -> [Pin] {
        guard !edges.isEmpty else {
            return []
        }
        let length = Swift.max(1, track.count)
        let aggregate = edges
            .filter { edge in !(!track.isEmpty && track.allSatisfy { $0.canonicalString == edge.canonicalString }) }
            .map { Pin(seam: seam, value: $0, position: nil) }

        var positional: [Pin] = []
        if length > 1 {
            // Enough turns that every reading is pinned in isolation, cycling the edges where a domain
            // has fewer of them than the track has slots. Rotating only `edges.count` times left every
            // later slot reachable *only* by the aggregate pin — silently, and more so the higher
            // `.repeating(_:)` went.
            for turn in 0 ..< Swift.max(edges.count, length) {
                let edge = edges[turn % edges.count]
                let position = turn % length
                guard position >= track.count || track[position].canonicalString != edge.canonicalString
                else { continue }
                positional.append(Pin(seam: seam, value: edge, position: position))
            }
        }

        // Interleaved, not tiered, so a truncated budget still gets both flavors of this seam.
        var pins: [Pin] = []
        for index in 0 ..< Swift.max(aggregate.count, positional.count) {
            if index < aggregate.count {
                pins.append(aggregate[index])
            }
            if index < positional.count {
                pins.append(positional[index])
            }
        }
        return pins
    }

    /// Which stream variant `index` draws from. Even variants are edge pins and odd ones combined,
    /// until the pins run out; from there every variant is combined, and the combined stream itself
    /// goes random once its scheduled head is spent.
    private static func slot(forVariant index: Int, edges: [Pin], combined: [Combined]) -> Slot {
        let interleaved = 2 * edges.count
        if index < interleaved {
            if index.isMultiple(of: 2) {
                return .edge(edges[index / 2])
            }
            let position = index / 2
            return position < combined.count ? .combined(combined[position]) : .random
        }
        let position = edges.count + (index - interleaved)
        return position < combined.count ? .combined(combined[position]) : .random
    }

    public var variedSeams: Set<String> {
        Set(domains.keys)
    }

    /// How many boundary-edge variants the schedule holds. A budget below twice this leaves part of
    /// the schedule unrun (`beginVariant` interleaves combined variants between pins) — exposing the
    /// count is what lets a verdict report "boundary edges N of M" instead of silently reading as
    /// edge-complete.
    public var scheduledBoundaryEdges: Int {
        edges.count
    }

    /// How many edge pins a budget of `variants` runs: every other slot until the schedule is spent.
    public func boundaryEdgesCovered(within variants: Int) -> Int {
        Swift.min(edges.count, Swift.max(0, (variants + 1) / 2))
    }

    /// How many variants of `variants` move every declared seam at once — all-edges vectors, interior
    /// rungs, and uniform samples together: the budget's share that reaches a pairing of two seams'
    /// values.
    public func combinedVariantsCovered(within variants: Int) -> Int {
        Swift.max(0, variants) - boundaryEdgesCovered(within: variants)
    }

    public mutating func beginVariant(_ index: Int) {
        slot = Self.slot(forVariant: index, edges: edges, combined: combined)
    }

    public mutating func generate(seam: String, at position: Int, like recorded: CanonicalValue) -> CanonicalValue {
        guard let domain = domains[seam] else { return recorded } // undeclared seam → keep golden
        switch slot {
        case .random:
            return domain.sample(using: &rng)
        case let .edge(pinned):
            guard pinned.seam == seam else { return recorded } // one factor at a time
            guard let pinnedPosition = pinned.position else { return pinned.value } // the aggregate edge
            return pinnedPosition == position ? pinned.value : recorded
        case .combined(.lowEdges):
            return domain.extremes.low
        case .combined(.highEdges):
            return domain.extremes.high
        case let .combined(.interior(index)):
            return domain.interior(at: index) ?? recorded
        }
    }
}

private extension SeamDomain {
    /// The interior rung a combined variant reads, cycling a domain with fewer rungs than the widest.
    func interior(at index: Int) -> CanonicalValue? {
        let values = interiorValues
        return values.isEmpty ? nil : values[index % values.count]
    }
}

// MARK: - Variant generation from the golden template

public extension CassetteData {
    /// Produces `count` variants of this golden cassette, asking `generator` for each reading. The golden
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
        var generator = DomainSeamGenerator(domains: domains, seed: seed, golden: tracks)
        return generatedVariants(count: count, using: &generator)
    }
}
