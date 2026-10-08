import Foundation
import HaruspecCore

/// A differential property over a golden cassette: baseline and candidate run against the *same*
/// generated cassette and their traces are diffed. Because both branches exist, the baseline *is* the
/// oracle, and a divergence on a generated input is a path-dependent difference the single golden
/// cassette never exercised.
///
/// The property is `baseline(x) ≡ candidate(x)` for every generated seam vector `x`.
public struct DifferentialProperty {
    /// Which side of the differential a run is for.
    public enum Branch: Sendable { case baseline, candidate }

    /// The golden cassette: the seam skeleton + a domain sample. Its tracks are the generation template.
    public let golden: CassetteData
    /// Runs the code for a branch against a replay cassette, returning its behavior trace.
    public let run: (Cassette, Branch) -> Trace
    /// The comparison for the branch-vs-branch diff (default: strict parity).
    public let comparison: Comparison

    public init(
        golden: CassetteData,
        comparison: Comparison = .strict,
        run: @escaping (Cassette, Branch) -> Trace
    ) {
        self.golden = golden
        self.comparison = comparison
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

    /// Diffs baseline vs candidate over `count` generated variants, stopping at (and shrinking) the first
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
        let coverage = Coverage(
            declared: allSeams,
            exercised: allSeams,
            gaps: [],
            domainExercised: held ? Array(swept) : []
        )
        return Result(checked: variants.count, counterexamples: counterexamples, coverage: coverage)
    }

    /// Convenience: check with the built-in domain generator (dependency-free). `varying` names the
    /// seams to generate; the rest replay their golden values.
    public func check(
        count: Int,
        varying domains: [String: SeamDomain],
        seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) -> Result {
        check(count: count, using: DomainSeamGenerator(domains: domains, seed: seed))
    }

    /// The resolved verdict for a property run, in the engine's own `VerificationResult` vocabulary:
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
    public func verify(
        count: Int,
        varying domains: [String: SeamDomain],
        seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) -> VerificationResult {
        verify(count: count, using: DomainSeamGenerator(domains: domains, seed: seed))
    }

    /// Runs both branches against one variant and diffs them.
    private func diff(on variant: CassetteData) -> TraceDiff {
        let baselineReplay = Cassette(replaying: variant)
        let baseline = run(baselineReplay, .baseline)
        let candidate = run(Cassette(replaying: baselineReplay.snapshot()), .candidate)
        return BehavioralDiff.compare(baseline: baseline, candidate: candidate, comparison: comparison)
    }

    /// The diff iff the two branches diverge on this variant.
    private func diverges(on variant: CassetteData) -> TraceDiff? {
        let result = diff(on: variant)
        return result.isEquivalent ? nil : result
    }

    /// Delta-debugging-lite localization: reset each seam to its golden reading and keep the reset only
    /// if the divergence survives. What's left generated is the minimal set of *readings* needed to
    /// reproduce — the "localize the change" the engine's north star asks for. Iterating *all* golden
    /// seams (sorted for a deterministic result) is correct regardless of which the generator varied: an
    /// un-varied seam already equals golden, so resetting it is a harmless no-op.
    ///
    /// Two tiers, because a seam read once per op occurrence has a whole track: the cheap pass drops a
    /// seam that doesn't matter at all, and only a seam that survives it is walked reading by reading.
    /// Without the second tier a counterexample says "this whole track was extreme" when the truth is
    /// "the second add was" — which is the difference between a reproduction and a lead.
    private func shrink(_ failing: CassetteData) -> CassetteData {
        var minimal = failing
        for seam in golden.tracks.keys.sorted() {
            guard let goldenTrack = golden.tracks[seam] else { continue }
            var whole = minimal
            whole.tracks[seam] = goldenTrack // restore the benign golden reading
            if diverges(on: whole) != nil {
                minimal = whole // seam wasn't necessary → drop it from the counterexample
                continue
            }
            for position in goldenTrack.indices {
                var trial = minimal
                guard var track = trial.tracks[seam], position < track.count else { continue }
                track[position] = goldenTrack[position]
                trial.tracks[seam] = track
                if diverges(on: trial) != nil {
                    minimal = trial // this reading wasn't necessary either
                }
            }
        }
        return minimal
    }
}
