import Foundation
import HaruspecCore

/// Turns a *replayed* cassette into the engine's seam-agnostic `Coverage` signal, so a
/// `VerificationResult` can downgrade an EQUIVALENT it can't stand behind. This adapter is the one
/// place the cassette (an `HaruspecSeams` concept) meets `Coverage` (an `HaruspecCore` concept); the diff
/// engine never sees a cassette.
public extension Cassette {
    /// Returns the coverage signal for this replay against a declared seam registry.
    ///
    /// - Parameter registry: The seam ids of the boundaries the harness knows about; `nil` means the
    ///   seams this cassette has tracks for.
    /// - Returns: The coverage, declaring every registry seam, with each cleanly exercised seam counted
    ///   and a gap for each unreached seam and each miss.
    ///
    /// The **registry is the coverage map** (docs/seams.md): the boundaries the harness knows about. When it
    /// isn't declared explicitly it defaults to the seams the golden run recorded — an honest but
    /// *partial* denominator (it can't see boundaries no one recorded — see `Coverage` for the
    /// sources the model absorbs beyond replay). Only meaningful after a `.replay` run.
    ///
    /// Mapping, per declared seam:
    ///  - had a `SeamMiss` → an `.unrecorded` gap (replay fell back to live; isolation broke).
    ///  - exercised cleanly (cursor advanced, no miss) → counted in `exercised`.
    ///  - never reached → an `.unexercised` gap.
    ///
    /// A miss on an **undeclared** seam is still recorded as an `.unrecorded` gap: the change crossed a
    /// boundary outside the registry, which is exactly what must downgrade the verdict.
    func coverage(declaring registry: [String]? = nil) -> Coverage {
        let recorded = Set(snapshot().tracks.keys)
        let declared = Set(registry ?? Array(recorded))
        let progress = replayProgress
        let observedMisses = misses
        let missedSeams = Set(observedMisses.map(\.seam))

        var exercised: [String] = []
        var gaps: [Coverage.Gap] = []

        for seam in declared where !missedSeams.contains(seam) {
            if (progress[seam] ?? 0) > 0 {
                exercised.append(seam)
            } else {
                gaps.append(Coverage.Gap(boundary: seam, reason: .unexercised))
            }
        }

        // Every miss is an unrecorded-reach gap — including misses on seams outside the registry.
        for miss in observedMisses {
            gaps.append(Coverage.Gap(boundary: miss.seam, ordinal: miss.ordinal, reason: .unrecorded))
        }

        return Coverage(declared: Array(declared), exercised: exercised, gaps: gaps)
    }

    /// Returns a trace diff paired with this replay's coverage, as the resolved `VerificationResult`.
    ///
    /// - Parameters:
    ///   - diff: The trace diff of the run this cassette replayed into.
    ///   - registry: The seam ids of the boundaries the harness knows about; `nil` means the seams this
    ///     cassette has tracks for.
    /// - Returns: The result over `diff`, with coverage as ``coverage(declaring:)`` reports it.
    func verify(_ diff: TraceDiff, declaring registry: [String]? = nil) -> VerificationResult {
        VerificationResult(diff: diff, coverage: coverage(declaring: registry))
    }
}
