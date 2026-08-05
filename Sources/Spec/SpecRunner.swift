import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

/// The outcome of a spec run: the three-tier verdict *with the coverage it was measured over*, how
/// much was explored, and — for an order-dependent divergence — the failing call sequence: shrunk to
/// minimal by `verify(against:)`, but the *raw recorded ordering* on `verify(replaying:)`, which never
/// shrinks (a shrunk variant has no recorded golden to diff against).
/// `Codable`, so a verify run is writable as a `result.json` artifact a reviewer can read and reproduce.
public struct SpecVerdict: Codable, Sendable {
    /// The diff + coverage pair carrying the *resolved* verdict (see `VerificationResult`): an
    /// EQUIVALENT the replay can't stand behind (an op or seam fell back to live) downgrades to
    /// CANNOT-VERIFY; a DIVERGED always stands.
    public let result: VerificationResult
    public let orderingsExplored: Int
    public let failingOrder: [String]?
    /// Declared `.after` preconditions the failing order broke, as `"removeMug after addMug"`. That
    /// stratum is explored on purpose, so a divergence here is a finding about a defensive path — worth
    /// separating from one on the surface the author described. Empty on an in-order failure, `nil`
    /// where no order was reported at all.
    public let violatedPreconditions: [String]?
    /// The generated input that triggered a divergence (its varied seam values are the counterexample).
    public let counterexample: CassetteData?
    /// The budget spent and the surface it covered. Optional because artifacts written before the
    /// budget existed carry no such field — an old `result.json` still decodes, it just can't say what
    /// fraction it swept.
    public let exploration: Exploration?

    public init(
        result: VerificationResult,
        orderingsExplored: Int,
        failingOrder: [String]?,
        counterexample: CassetteData?,
        exploration: Exploration? = nil,
        violatedPreconditions: [String]? = nil
    ) {
        self.result = result
        self.orderingsExplored = orderingsExplored
        self.failingOrder = failingOrder
        self.counterexample = counterexample
        self.exploration = exploration
        self.violatedPreconditions = violatedPreconditions
    }

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
                     "  explored: \(exploration?.summary ?? "\(orderingsExplored) orderings")"]
        if let fraction = coverage.fraction {
            var line = "  coverage: \(Int((fraction * 100).rounded()))% "
                + "of \(coverage.declared.count) declared boundaries"
            // Printed at 0 too: a spec that declared domains and swept none of them is exactly the
            // case worth saying out loud, and gating the clause on `> 0` hid it.
            if let domain = coverage.domainFraction, !coverage.domainExercised.isEmpty || domain == 0 {
                line += " · domain-swept \(Int((domain * 100).rounded()))%"
            }
            lines.append(line)
            for gap in coverage.unrecordedReach {
                lines.append("    ⚠︎ unrecorded reach: \(gap.boundary) (replay fell back to live)")
            }
            for gap in coverage.unmatchedDomains {
                lines.append("    ⚠︎ declared domain matched nothing: \(gap.boundary) (nothing read that seam)")
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
        lines += failingOrderLines
        let seams = counterexampleSeamPairs
        if !seams.isEmpty {
            lines.append("  ↳ counterexample: \(seams.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    /// The failing call sequence, and — when it came from the out-of-order stratum — which declared
    /// precondition it broke. Triage differs: a divergence on a path the author said shouldn't happen
    /// is a defensive-code finding, not a regression on the described surface.
    private var failingOrderLines: [String] {
        guard let failing = failingOrder else {
            return []
        }
        var lines = ["  ↳ failing order: \(failing.joined(separator: " → "))"]
        if let violated = violatedPreconditions, !violated.isEmpty {
            lines.append("    ⚠︎ out-of-order: breaks \(violated.joined(separator: ", "))")
        }
        return lines
    }

    /// The counterexample's seam values as `(key, value)` pairs, e.g. `("add.quantity", "1,20")` —
    /// one entry per reading, so a repeatedly-read seam shows which position was extreme. Shared by
    /// `report()` and `htmlReport()` so the extraction lives in one place.
    ///
    /// Every value type renders, not only integers: a categorical argument (`.oneOf(Catalog.all)`) is
    /// the input a counterexample most needs to name, and dropping it left the reader with a quantity
    /// and no SKU.
    var counterexampleSeamPairs: [(key: String, value: String)] {
        guard let tracks = counterexample?.tracks else { return [] }
        let rendered = tracks.compactMapValues { values -> String? in
            values.isEmpty ? nil : values.map(Self.render).joined(separator: ",")
        }
        return rendered.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }

    /// Unquoted for a report line — `add.sku=COFFEE` reads better than `add.sku="COFFEE"`, and the
    /// serialized cassette is the artifact anything machine-read should use.
    private static func render(_ value: CanonicalValue) -> String {
        if case let .string(text) = value {
            return text
        }
        return value.canonicalString
    }
}

/// The generation constants shared by the live differential (`verify(against:)`) and the recorded plan
/// (`record()` / `verify(replaying:)`) — one surface, whichever side of a build boundary it runs on.
enum SpecDefaults {
    static let seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    /// Seam cassettes per ordering when no `Budget(runs:)` is declared.
    static let variantCount = 64
    /// Where counting valid orderings gives up and reports a lower bound. A denominator is worth a few
    /// milliseconds, not a factorial walk.
    static let orderingCountLimit = 100_000
    /// The share of a sampled ordering budget spent on sequences that break a declared `.after`
    /// precondition. A quarter is enough that every declared precondition is broken several times over
    /// at a typical `Ordering(max: 50)`, while the bulk of the sweep stays on the surface the author
    /// described. Zero when a spec declares no preconditions — there is no such stratum to draw from.
    static let outOfOrderShare = 0.25
    /// How many distinct occurrence-count shapes a spec's declared `.repeating(_:)` ranges may produce
    /// before shapes are sampled rather than enumerated. Generous: the product only grows when an author
    /// declares several ranged ops, and the fallback is a lower-bound denominator, not a wrong one.
    static let shapeLimit = 4096
    /// How many times the sampler revisits every shape. Each pass draws at most one ordering per shape,
    /// so this bounds the work when most shapes are exhausted and the budget still isn't spent.
    static let shapePasses = 8
}

public extension Spec {
    /// Differentially verify a candidate implementation against this spec's baseline: run both
    /// against the *same* generated inputs (call orderings × seam values) and diff. The baseline branch
    /// is the oracle, so no expected output is needed. Stops at (and shrinks) the first divergence.
    func verify(against candidate: @escaping (SeamContext) -> S) -> SpecVerdict {
        // Golden: the declared order under live seams — the template every variation is derived from.
        let recording = Cassette()
        _ = capture(make: makeSystem, order: explorationOrder(), cassette: recording)
        let golden = recording.snapshot()

        let plan = explorationPlan(golden: golden)

        for (index, order) in plan.orderings.enumerated() {
            for cassette in plan.cassettes(forOrdering: index) {
                let run = compare(make: makeSystem, candidate: candidate, order: order, cassette: cassette)
                guard run.diff.isEquivalent else {
                    let shrunk = shrink(candidate: candidate, failing: order, cassette: cassette)
                    let coverage = coverage(replays: [run.candidateReplay], domainHeld: false)
                    let failing = exploreOrdering ? shrunk.map(\.label) : nil
                    return SpecVerdict(
                        result: VerificationResult(diff: run.diff, coverage: coverage),
                        orderingsExplored: plan.orderings.count,
                        failingOrder: failing,
                        counterexample: seamDomains.isEmpty ? nil : cassette,
                        exploration: plan.exploration,
                        violatedPreconditions: failing.map(preconditionViolations(in:))
                    )
                }
            }
        }
        // Held across the whole explored surface: the swept seams earn domain-coverage credit.
        let representative = compare(make: makeSystem, candidate: candidate, order: operations, cassette: golden)
        let coverage = coverage(replays: [representative.candidateReplay], domainHeld: true)
        return SpecVerdict(
            result: VerificationResult(diff: representative.diff, coverage: coverage),
            orderingsExplored: plan.orderings.count,
            failingOrder: nil,
            counterexample: nil,
            exploration: plan.exploration
        )
    }

    // MARK: - Hidden machinery

    /// The longest call sequence exploration can produce: the declared ops, each repeated as far as
    /// `Ordering(repeating:)` allows. The golden cassette is recorded over *this* rather than the
    /// declared order, so every explored ordering has enough recorded seam readings — a shorter one
    /// just consumes a prefix of each track. Recording over the declared order instead would leave a
    /// repeated op's second read with nothing to replay, which surfaces as an `.unrecorded` gap and
    /// downgrades an otherwise-equivalent verdict to CANNOT-VERIFY.
    func explorationOrder() -> [Op<S>] {
        guard exploreOrdering else {
            return operations
        }
        return operations.flatMap { operation in
            Array(repeating: operation, count: operation.occurrences(default: orderingRepeats).upperBound)
        }
    }

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

    /// Assemble the spec's coverage: the declared surface is the *interrogation* surface — every op
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

        // A domain declared for a key nothing read applied to nothing, and the run reports a swept
        // surface it never swept. Only knowable once the golden has been recorded — which reads is not
        // a static property of a spec — so it is caught here rather than at construction.
        let declaredDomains = Set(sweptSeams ?? Array(seamDomains.keys))
        let unmatched = declaredDomains.subtracting(declared).sorted()
        gaps += unmatched.map { Coverage.Gap(boundary: $0, reason: .unmatchedDomain) }

        let swept = domainHeld ? declaredDomains.intersection(declared) : []
        return Coverage(
            // An unmatched domain joins the declared surface: the author declared it, and leaving it out
            // would report a fraction of a surface quietly smaller than the one the spec describes.
            declared: opBoundaries + declared.sorted() + unmatched,
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
