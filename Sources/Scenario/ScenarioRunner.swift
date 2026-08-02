import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

/// The outcome of a scenario run: the three-tier verdict *with the coverage it was measured over*, how
/// much was explored, and — for an order-dependent divergence — the failing call sequence: shrunk to
/// minimal by `verify(against:)`, but the *raw recorded ordering* on `verify(replaying:)`, which never
/// shrinks (a shrunk variant has no recorded golden to diff against).
/// `Codable`, so a verify run is writable as a `result.json` artifact a reviewer can read and reproduce.
public struct ScenarioVerdict: Codable, Sendable {
    /// The diff + coverage pair carrying the *resolved* verdict (see `VerificationResult`): an
    /// EQUIVALENT the replay can't stand behind (an op or seam fell back to live) downgrades to
    /// CANNOT-VERIFY; a DIVERGED always stands.
    public let result: VerificationResult
    public let orderingsExplored: Int
    public let failingOrder: [String]?
    /// The generated input that triggered a divergence (its varied seam values are the counterexample).
    public let counterexample: CassetteData?

    public var verdict: TraceDiff.Verdict {
        result.verdict
    }

    public var diff: TraceDiff {
        result.diff
    }

    /// The declared interrogation surface (`op:` boundaries + seams) and how much of it was exercised.
    public var coverage: Coverage {
        result.coverage
    }

    /// A compact rendering built from the diff's public surface (a caller / LLM would print this).
    public func report() -> String {
        let banner = switch verdict {
        case .equivalent: "✅ EQUIVALENT"
        case .diverged: "❌ DIVERGED"
        case .cannotVerify: "⚠️ CANNOT-VERIFY"
        }
        var lines = ["\(banner)  \(diff.baselineName) → \(diff.candidateName)",
                     "  orderings explored: \(orderingsExplored)"]
        if let fraction = coverage.fraction {
            var line = "  coverage: \(Int((fraction * 100).rounded()))% "
                + "of \(coverage.declared.count) declared boundaries"
            if let domain = coverage.domainFraction, domain > 0 {
                line += " · domain-swept \(Int((domain * 100).rounded()))%"
            }
            lines.append(line)
            for gap in coverage.unrecordedReach {
                lines.append("    ⚠︎ unrecorded reach: \(gap.boundary) (replay fell back to live)")
            }
        }
        if diff.divergences.isEmpty {
            lines.append("  behavior matches across everything explored (0 divergences)")
        } else {
            lines.append("  \(diff.divergences.count) divergence(s):")
            for divergence in diff.divergences {
                let mark = divergence.classification == .intended ? "✓ intended " : "≠ "
                lines.append("    \(mark)\(divergence.label): \(divergence.detail)")
            }
        }
        if let failing = failingOrder {
            lines.append("  ↳ failing order: \(failing.joined(separator: " → "))")
        }
        let seams = counterexampleSeamPairs
        if !seams.isEmpty {
            lines.append("  ↳ counterexample: \(seams.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    /// The varied integer seam values of the counterexample as `(key, value)` pairs, e.g.
    /// `("coffeeQty", "1")`. Shared by `report()` and `htmlReport()` so the extraction lives in one place.
    var counterexampleSeamPairs: [(key: String, value: String)] {
        guard let tracks = counterexample?.tracks else { return [] }
        let ints = tracks.compactMapValues { values -> String? in
            let rendered = values.compactMap {
                if case let .int(intValue) = $0 {
                    String(intValue)
                } else {
                    nil
                }
            }
            return rendered.isEmpty ? nil : rendered.joined(separator: ",")
        }
        return ints.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }
}

/// The generation constants shared by the live differential (`verify(against:)`) and the recorded plan
/// (`record()` / `verify(replaying:)`) — one surface, whichever side of a build boundary it runs on.
enum ScenarioDefaults {
    static let seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    static let variantCount = 64
}

public extension Scenario {
    /// Differentially verify a candidate implementation against this scenario's baseline: run both
    /// against the *same* generated inputs (call orderings × seam values) and diff. The baseline branch
    /// is the oracle, so no expected output is needed. Stops at (and shrinks) the first divergence.
    func verify(against candidate: @escaping (SeamContext) -> S) -> ScenarioVerdict {
        // Golden: the declared order under live seams — the template every variation is derived from.
        let recording = Cassette()
        _ = capture(make: makeSystem, order: operations, cassette: recording)
        let golden = recording.snapshot()

        let orderings = exploreOrdering ? linearExtensions(operations, max: maxOrderings) : [operations]

        for order in orderings {
            let cassettes = seamDomains.isEmpty
                ? [golden]
                : golden.generatedVariants(
                    count: ScenarioDefaults.variantCount,
                    varying: seamDomains,
                    seed: ScenarioDefaults.seed
                )
            for cassette in cassettes {
                let run = compare(make: makeSystem, candidate: candidate, order: order, cassette: cassette)
                guard run.diff.isEquivalent else {
                    let shrunk = shrink(candidate: candidate, failing: order, cassette: cassette)
                    let coverage = coverage(replays: [run.candidateReplay], domainHeld: false)
                    return ScenarioVerdict(
                        result: VerificationResult(diff: run.diff, coverage: coverage),
                        orderingsExplored: orderings.count,
                        failingOrder: exploreOrdering ? shrunk.map(\.label) : nil,
                        counterexample: seamDomains.isEmpty ? nil : cassette
                    )
                }
            }
        }
        // Held across the whole explored surface: the swept seams earn domain-coverage credit.
        let representative = compare(make: makeSystem, candidate: candidate, order: operations, cassette: golden)
        let coverage = coverage(replays: [representative.candidateReplay], domainHeld: true)
        return ScenarioVerdict(
            result: VerificationResult(diff: representative.diff, coverage: coverage),
            orderingsExplored: orderings.count,
            failingOrder: nil,
            counterexample: nil
        )
    }

    // MARK: - Hidden machinery

    /// Drive one (system, ordering, cassette) and return its behavior trace — the recorder, interceptor,
    /// and ambient context the developer never touches. (Internal: `record`/`verify(replaying:)` drive
    /// the same primitive across a build boundary.)
    func capture(make: (SeamContext) -> S, order: [Op<S>], cassette: Cassette) -> Trace {
        let recorder = TraceRecorder(name: name, clock: ManualClock())
        let center = observationCenter ?? NotificationCenter()
        let interceptor = NotificationInterceptor(recorder: recorder, center: center, names: notificationNames)
        interceptor.start(); defer { interceptor.stop() }
        let context = SeamContext(notifications: center, cassette: cassette)
        let system = make(context)
        TraceContext.$current.withValue(recorder) {
            for operation in order {
                operation.action(system, context)
            }
        }
        return recorder.trace()
    }

    /// One differential run, keeping the candidate's replay cassette so the verdict can carry the
    /// coverage it was measured over. The diff is already intent-classified: with a declared intent the
    /// loop must not stop on an intended-only divergence set, so classification lives here, not at exits.
    private func compare(
        make: (SeamContext) -> S,
        candidate: (SeamContext) -> S,
        order: [Op<S>],
        cassette: CassetteData
    ) -> (diff: TraceDiff, candidateReplay: Cassette) {
        let baseline = capture(make: make, order: order, cassette: Cassette(replaying: cassette))
        let replay = Cassette(replaying: cassette)
        let candidateTrace = capture(make: candidate, order: order, cassette: replay)
        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidateTrace, tolerances: tolerances)
            .classified(against: intent)
        return (diff, replay)
    }

    private func diverges(candidate: (SeamContext) -> S, order: [Op<S>], cassette: CassetteData) -> TraceDiff? {
        let diff = compare(make: makeSystem, candidate: candidate, order: order, cassette: cassette).diff
        return diff.isEquivalent ? nil : diff
    }

    /// Assemble the scenario's coverage: the declared surface is the *interrogation* surface — every op
    /// (as an `op:<label>` boundary) plus every seam the replays declared. Ops all ran by construction
    /// here (the replay path is where an op can go unrecorded); seams merge across the given replays,
    /// and a seam missed anywhere is never counted exercised. `domainHeld` awards the swept seams
    /// domain-coverage credit — additive evidence, only when the property held over the surface.
    func coverage(
        replays: [Cassette],
        domainHeld: Bool,
        declaredOps: [String]? = nil,
        missingOps: [String] = [],
        sweptSeams: [String]? = nil
    ) -> Coverage {
        var declared = Set<String>(), exercised = Set<String>()
        var gaps: [Coverage.Gap] = []
        var seenGaps = Set<String>()
        for replay in replays {
            let seams = replay.coverage()
            declared.formUnion(seams.declared)
            exercised.formUnion(seams.exercised)
            for gap in seams.gaps where gap.reason == .unrecorded {
                let key = "\(gap.boundary)#\(gap.ordinal ?? -1)"
                if seenGaps.insert(key).inserted {
                    gaps.append(gap)
                }
            }
        }
        let missedSeams = Set(gaps.map(\.boundary))
        exercised.subtract(missedSeams)
        for seam in declared where !exercised.contains(seam) && !missedSeams.contains(seam) {
            gaps.append(Coverage.Gap(boundary: seam, reason: .unexercised))
        }

        let ops = declaredOps ?? operations.map(\.label)
        let opBoundaries = ops.map { "op:\($0)" }
        let exercisedOps = ops.filter { !missingOps.contains($0) }.map { "op:\($0)" }
        gaps += missingOps.map { Coverage.Gap(boundary: "op:\($0)", reason: .unrecorded) }

        let swept = domainHeld ? Set(sweptSeams ?? Array(seamDomains.keys)).intersection(declared) : []
        return Coverage(
            declared: opBoundaries + declared.sorted(),
            exercised: exercisedOps + exercised.sorted(),
            gaps: gaps,
            domainExercised: swept.sorted()
        )
    }

    /// Delta-debug the failing call sequence: drop ops that aren't needed to reproduce → the minimal
    /// order that still diverges (the "localize" the north star asks for, applied to sequencing).
    private func shrink(candidate: @escaping (SeamContext) -> S, failing: [Op<S>], cassette: CassetteData) -> [Op<S>] {
        var minimal = failing
        var index = 0
        while index < minimal.count {
            var trial = minimal
            trial.remove(at: index)
            if !trial.isEmpty, diverges(candidate: candidate, order: trial, cassette: cassette) != nil {
                minimal = trial // op wasn't needed to reproduce
            } else {
                index += 1
            }
        }
        return minimal
    }
}

/// Enumerate linear extensions of the declared partial order (respecting `.after` and `.last`), capped.
/// Full N! never happens; constraints prune to orderings a real caller could produce.
func linearExtensions<S>(_ ops: [Op<S>], max: Int) -> [[Op<S>]] {
    var result: [[Op<S>]] = []
    func recurse(_ placed: [Op<S>], _ remaining: [Op<S>]) {
        if result.count >= max {
            return
        }
        if remaining.isEmpty {
            result.append(placed); return
        }
        let done = Set(placed.map(\.label))
        for operation in remaining {
            guard operation.afters.allSatisfy(done.contains) else { continue }
            if operation.mustBeLast, remaining.count > 1 {
                continue
            }
            recurse(placed + [operation], remaining.filter { $0.label != operation.label })
        }
    }
    recurse([], ops)
    return result
}
