import Foundation
import HaruspecCore

// The Continuous (PR) shape's entry points: record a bound baseline's plan on the base build, and
// replay it into the same binding on the changed build. The plan format and the replay machinery live
// in `SpecPlan.swift`.

public extension BaselinedSpec {
    /// Runs the bound baseline across the whole explored surface (call orderings × seam cassettes)
    /// and pins every (input, golden trace) pair into a `SpecPlan`. Run on the **base** build.
    ///
    /// - Returns: The plan, named for the spec; its first probe is the declared order under the golden
    ///   cassette — the representative run.
    func record() async -> SpecPlan {
        await spec.record(baseline: baseline)
    }

    /// Records the plan, as ``record()`` does, and writes it as an artifact.
    ///
    /// - Parameter url: Where the plan is written; a `.gz` extension compresses it.
    /// - Returns: The plan written.
    /// - Throws: The file system's error when the plan cannot be written.
    @discardableResult
    func record(to url: URL) async throws -> SpecPlan {
        let plan = await record()
        try plan.write(to: url)
        return plan
    }

    /// Replays every probe's recorded inputs into the **current** build of the bound baseline and
    /// diffs against the stored golden traces, so a reviewer re-running the plan gets the same verdict.
    ///
    /// - Parameters:
    ///   - plan: A plan recorded on the base build.
    ///   - intent: The deltas the change is meant to produce; `.none` asks for parity.
    ///   - replays: How many passes must agree; at least one.
    /// - Returns: The first pass's verdict, qualified by the agreement across passes.
    ///
    /// Divergence semantics match ``verify(candidate:declaring:)`` except at the exit: no shrink (shrunk
    /// orderings have no recorded golden to compare against). Like it, a red walks every probe,
    /// reporting the richest failing case and carrying every one (`FailingCases`); intent-declared
    /// deltas are absorbed and the residual collateral gates. Inputs the current build can't
    /// reproduce (a renamed/removed op, a seam read past the recording) downgrade an otherwise
    /// EQUIVALENT verdict to CANNOT-VERIFY via `.unrecorded` coverage gaps.
    ///
    /// Every pass must reach the same verdict with the same divergence inventory — disagreement flips
    /// the verdict to UNSTABLE and carries the run-to-run delta rather than either pass (see
    /// `Stability`). The passes are sequential and share nothing but the immutable plan.
    func verify(
        replaying plan: SpecPlan,
        declaring intent: Intent = .none,
        replays: Int = Stability.defaultReplays
    ) async -> SpecVerdict {
        await spec.verify(replaying: plan, into: baseline, declaring: intent, replays: replays)
    }

    /// Replays a plan artifact on disk, as ``verify(replaying:declaring:replays:)`` does.
    ///
    /// - Parameters:
    ///   - url: The plan artifact, plain or gzipped.
    ///   - intent: The deltas the change is meant to produce; `.none` asks for parity.
    ///   - replays: How many passes must agree; at least one.
    /// - Returns: The first pass's verdict, qualified by the agreement across passes.
    /// - Throws: The read or decode error when the plan cannot be loaded.
    func verify(
        replayingContentsOf url: URL,
        declaring intent: Intent = .none,
        replays: Int = Stability.defaultReplays
    ) async throws -> SpecVerdict {
        try await verify(replaying: SpecPlan(contentsOf: url), declaring: intent, replays: replays)
    }
}
