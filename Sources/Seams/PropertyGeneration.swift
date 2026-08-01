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
    mutating func generate(seam: String, like recorded: CanonicalValue) -> CanonicalValue
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

/// The generation domain for one seam's readings. Scalar-only for the first cut; structured/corpus
/// domains (schema-aware network payloads, recorded-value distributions) are a later refinement.
public enum SeamDomain: Sendable {
    case int(ClosedRange<Int64>)
    case double(ClosedRange<Double>)

    func sample(using rng: inout SplitMix64) -> CanonicalValue {
        switch self {
        case let .int(range): .int(Int64.random(in: range, using: &rng))
        case let .double(range): .double(Double.random(in: range, using: &rng))
        }
    }
}

/// The built-in, dependency-free generator: uniform sampling over a declared per-seam `SeamDomain`,
/// seeded by SplitMix64. A seam with no declared domain replays its recorded value unchanged, so the
/// generated surface is exactly the declared seams. This is the default `SeamValueGenerator`; swapping
/// in a library-backed one is a one-type change.
public struct DomainSeamGenerator: SeamValueGenerator {
    public var domains: [String: SeamDomain]
    private var rng: SplitMix64

    public init(domains: [String: SeamDomain], seed: UInt64) {
        self.domains = domains
        rng = SplitMix64(seed: seed)
    }

    public var variedSeams: Set<String> {
        Set(domains.keys)
    }

    public mutating func generate(seam: String, like recorded: CanonicalValue) -> CanonicalValue {
        guard let domain = domains[seam] else { return recorded } // undeclared seam → keep golden
        return domain.sample(using: &rng)
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
        for _ in 0 ..< max(0, count) {
            var newTracks = tracks
            for (seam, track) in tracks {
                var newTrack: [CanonicalValue] = []
                newTrack.reserveCapacity(track.count)
                for value in track {
                    newTrack.append(generator.generate(seam: seam, like: value))
                }
                newTracks[seam] = newTrack
            }
            variants.append(CassetteData(schemaVersion: schemaVersion, tracks: newTracks))
        }
        return variants
    }

    /// Convenience: variants via the built-in domain generator (dependency-free).
    func generatedVariants(count: Int, varying domains: [String: SeamDomain], seed: UInt64) -> [CassetteData] {
        var generator = DomainSeamGenerator(domains: domains, seed: seed)
        return generatedVariants(count: count, using: &generator)
    }
}

// MARK: - The differential property

/// A differential property over a golden cassette: run a baseline and a candidate "session" against the
/// *same* generated cassette and diff them. The property is `baseline(x) ≡ candidate(x)` for every
/// generated seam-vector `x`. Because both branches exist, the baseline *is* the oracle — a divergence
/// on a generated input is a path-dependent difference the single golden cassette never exercised.
public struct DifferentialProperty {
    public enum Branch: Sendable { case baseline, candidate }

    /// The golden cassette: the seam skeleton + a domain sample. Its tracks are the generation template.
    public let golden: CassetteData
    /// Runs the code for a branch against a replay cassette, returning its behavior trace.
    public let run: (Cassette, Branch) -> Trace
    /// Tolerances for the branch-vs-branch diff (default: strict parity).
    public let tolerances: ToleranceSpec

    public init(golden: CassetteData,
                tolerances: ToleranceSpec = .strict,
                run: @escaping (Cassette, Branch) -> Trace) {
        self.golden = golden
        self.tolerances = tolerances
        self.run = run
    }

    /// A generated input for which baseline and candidate diverged.
    public struct Counterexample: Sendable {
        /// The exact generated cassette that triggers the divergence — serializable, so it drops
        /// straight in as a permanent regression fixture.
        public var cassette: CassetteData
        /// The localized diff between the two branches on this input.
        public var diff: TraceDiff
    }

    public struct Result: Sendable {
        /// How many generated inputs were checked.
        public var checked: Int
        /// The generated inputs that diverged (first is the reported / shrunk one).
        public var counterexamples: [Counterexample]
        /// The surface this run covered: the swept seams are `domainExercised` **iff** the property held
        /// over them (a divergence means the domain isn't cleared). Additive breadth on top of the
        /// single-cassette point coverage — reported, never a trust relaxation.
        public var coverage: Coverage
        /// True when `baseline ≡ candidate` held across the whole generated surface.
        public var heldOverSurface: Bool {
            counterexamples.isEmpty
        }

        /// The minimal reported counterexample, if any.
        public var firstFailure: Counterexample? {
            counterexamples.first
        }
    }

    /// Diff baseline vs candidate over `count` generated variants, stopping at (and shrinking) the first
    /// divergence. `generator` supplies the values — the commodity seam.
    public func check(count: Int, using generator: some SeamValueGenerator) -> Result {
        var gen = generator
        let variants = golden.generatedVariants(count: count, using: &gen)
        var counterexamples: [Counterexample] = []
        for variant in variants {
            if let divergence = diverges(on: variant) {
                counterexamples.append(Counterexample(cassette: shrink(variant), diff: divergence))
                break // first-failure reporting; a continue-and-collect policy is a later knob.
            }
        }
        let held = counterexamples.isEmpty
        let allSeams = Array(golden.tracks.keys)
        let swept = gen.variedSeams.intersection(golden.tracks.keys)
        // Every golden seam is boundary-exercised (every variant replays it with no miss); the swept
        // seams are additionally domain-exercised, but only when the property held over the surface.
        let coverage = Coverage(declared: allSeams,
                                exercised: allSeams,
                                gaps: [],
                                domainExercised: held ? Array(swept) : [])
        return Result(checked: variants.count, counterexamples: counterexamples, coverage: coverage)
    }

    /// Convenience: check with the built-in domain generator (dependency-free). `varying` names the
    /// seams to generate; the rest replay their golden values.
    public func check(count: Int,
                      varying domains: [String: SeamDomain],
                      seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Result {
        check(count: count, using: DomainSeamGenerator(domains: domains, seed: seed))
    }

    /// The three-tier verdict for a property run, in the engine's own `VerificationResult` vocabulary:
    ///  - held over the surface → the golden's `EQUIVALENT` diff, with the swept seams credited as
    ///    domain-exercised (breadth beyond the single point).
    ///  - a counterexample → its `DIVERGED` diff, which stands (a caught path-dependent regression).
    /// The domain credit is additive: it never flips a `CANNOT-VERIFY` to a pass (see `Coverage`).
    public func verify(count: Int, using generator: some SeamValueGenerator) -> VerificationResult {
        let result = check(count: count, using: generator)
        let representative = result.firstFailure?.diff ?? diff(on: golden)
        return VerificationResult(diff: representative, coverage: result.coverage)
    }

    /// Convenience: verify with the built-in domain generator (dependency-free).
    public func verify(count: Int,
                       varying domains: [String: SeamDomain],
                       seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> VerificationResult {
        verify(count: count, using: DomainSeamGenerator(domains: domains, seed: seed))
    }

    /// Run both branches against one variant and diff them.
    private func diff(on variant: CassetteData) -> TraceDiff {
        let baseline = run(Cassette(replaying: variant), .baseline)
        let candidate = run(Cassette(replaying: variant), .candidate)
        return BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: tolerances)
    }

    /// The diff iff the two branches diverge on this variant.
    private func diverges(on variant: CassetteData) -> TraceDiff? {
        let result = diff(on: variant)
        return result.isEquivalent ? nil : result
    }

    /// Delta-debugging-lite localization: reset each seam to its golden reading and keep the reset only
    /// if the divergence survives. What's left generated is the minimal set of seams needed to reproduce
    /// — the "localize the change" the engine's north star asks for. Iterating *all* golden seams (sorted
    /// for a deterministic result) is correct regardless of which the generator varied: an un-varied seam
    /// already equals golden, so resetting it is a harmless no-op. (Per-value minimization *within* a
    /// responsible seam is a later refinement.)
    private func shrink(_ failing: CassetteData) -> CassetteData {
        var minimal = failing
        for seam in golden.tracks.keys.sorted() {
            guard let goldenTrack = golden.tracks[seam] else { continue }
            var trial = minimal
            trial.tracks[seam] = goldenTrack // restore the benign golden reading
            if diverges(on: trial) != nil {
                minimal = trial // seam wasn't necessary → drop it from the counterexample
            }
        }
        return minimal
    }
}
