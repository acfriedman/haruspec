import Foundation
import OracleCore
import OracleTrace
import OracleSeams

/// The outcome of a scenario run: the three-tier verdict, how much was explored, and — for an
/// order-dependent divergence — the minimal failing call sequence.
public struct ScenarioVerdict {
    public let verdict: TraceDiff.Verdict
    public let diff: TraceDiff
    public let orderingsExplored: Int
    public let failingOrder: [String]?
    /// The generated input that triggered a divergence (its varied seam values are the counterexample).
    public let counterexample: CassetteData?

    /// A compact rendering built from the diff's public surface (a caller / LLM would print this).
    public func report() -> String {
        let banner: String
        switch verdict {
        case .equivalent:   banner = "✅ EQUIVALENT"
        case .diverged:     banner = "❌ DIVERGED"
        case .cannotVerify: banner = "⚠️ CANNOT-VERIFY"
        }
        var lines = ["\(banner)  \(diff.baselineName) → \(diff.candidateName)",
                     "  orderings explored: \(orderingsExplored)"]
        if diff.divergences.isEmpty {
            lines.append("  behavior matches across everything explored (0 divergences)")
        } else {
            lines.append("  \(diff.divergences.count) divergence(s):")
            for d in diff.divergences { lines.append("    ≠ \(d.label): \(d.detail)") }
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
            let vs = values.compactMap { if case let .int(v) = $0 { return String(v) } else { return nil } }
            return vs.isEmpty ? nil : vs.joined(separator: ",")
        }
        return ints.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }
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
                : golden.generatedVariants(count: 64, varying: seamDomains, seed: 0x9E37_79B9_7F4A_7C15)
            for cassette in cassettes {
                if let diff = diverges(candidate: candidate, order: order, cassette: cassette) {
                    let shrunk = shrink(candidate: candidate, failing: order, cassette: cassette)
                    return ScenarioVerdict(verdict: .diverged, diff: diff,
                                           orderingsExplored: orderings.count,
                                           failingOrder: exploreOrdering ? shrunk.map(\.label) : nil,
                                           counterexample: seamDomains.isEmpty ? nil : cassette)
                }
            }
        }
        // Held across the whole explored surface.
        let representative = compare(make: makeSystem, candidate: candidate, order: operations, cassette: golden)
        return ScenarioVerdict(verdict: representative.verdict, diff: representative,
                               orderingsExplored: orderings.count, failingOrder: nil, counterexample: nil)
    }

    // MARK: - Hidden machinery

    /// Drive one (system, ordering, cassette) and return its behavior trace — the recorder, interceptor,
    /// and ambient context the developer never touches.
    private func capture(make: (SeamContext) -> S, order: [Op<S>], cassette: Cassette) -> Trace {
        let recorder = TraceRecorder(name: name, clock: ManualClock())
        let center = observationCenter ?? NotificationCenter()
        let interceptor = NotificationInterceptor(recorder: recorder, center: center, names: notificationNames)
        interceptor.start(); defer { interceptor.stop() }
        let context = SeamContext(notifications: center, cassette: cassette)
        let system = make(context)
        TraceContext.$current.withValue(recorder) {
            for op in order { op.action(system, context) }
        }
        return recorder.trace()
    }

    private func compare(make: (SeamContext) -> S, candidate: (SeamContext) -> S,
                         order: [Op<S>], cassette: CassetteData) -> TraceDiff {
        let baseline = capture(make: make, order: order, cassette: Cassette(replaying: cassette))
        let candidateTrace = capture(make: candidate, order: order, cassette: Cassette(replaying: cassette))
        return BehavioralDiff.compare(baseline: baseline, candidate: candidateTrace, tolerances: tolerances)
    }

    private func diverges(candidate: (SeamContext) -> S, order: [Op<S>], cassette: CassetteData) -> TraceDiff? {
        let diff = compare(make: makeSystem, candidate: candidate, order: order, cassette: cassette)
        return diff.isEquivalent ? nil : diff
    }

    /// Delta-debug the failing call sequence: drop ops that aren't needed to reproduce → the minimal
    /// order that still diverges (the "localize" the north star asks for, applied to sequencing).
    private func shrink(candidate: @escaping (SeamContext) -> S, failing: [Op<S>], cassette: CassetteData) -> [Op<S>] {
        var minimal = failing
        var i = 0
        while i < minimal.count {
            var trial = minimal
            trial.remove(at: i)
            if !trial.isEmpty, diverges(candidate: candidate, order: trial, cassette: cassette) != nil {
                minimal = trial            // op wasn't needed to reproduce
            } else {
                i += 1
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
        if result.count >= max { return }
        if remaining.isEmpty { result.append(placed); return }
        let done = Set(placed.map(\.label))
        for op in remaining {
            guard op.afters.allSatisfy(done.contains) else { continue }
            if op.mustBeLast && remaining.count > 1 { continue }
            recurse(placed + [op], remaining.filter { $0.label != op.label })
        }
    }
    recurse([], ops)
    return result
}
