import Foundation
import HaruspecCore
import HaruspecTrace
import HaruspecSeams

// The Continuous (PR) shape: one class, two *builds*. The Campaign shape (`verify(against:)`) diffs two
// implementations coexisting as types in one build; a PR has only one — base and branch are separate
// checkouts. `record()` runs on the base build and pins the whole explored input surface (call
// orderings × seam cassettes) together with the golden trace each input produced. `verify(replaying:)`
// runs on the changed build, replays the *identical* inputs from the plan into the current code, and
// diffs each run against its stored golden. The plan file is the reproducible PR evidence: a reviewer
// re-runs `verify(replaying:)` against it and gets the same verdict, bit for bit.
//
// Soundness across the boundary: inputs the current build can't faithfully reproduce (an op label that
// no longer exists, a seam read past the recording) surface as `.unrecorded` coverage gaps that
// downgrade an EQUIVALENT to CANNOT-VERIFY — never a silent skip, never a fabricated input.

/// One recorded interrogation: a call ordering, the seam inputs replayed into it, and the golden trace
/// the base build produced under exactly those inputs.
public struct ScenarioProbe: Codable, Sendable, Equatable {
    /// Op labels in execution order — the replay contract. Labels are the cross-build identity of an
    /// operation (the analog of `@Traced`'s stable labels), so renaming an op orphans recorded input.
    public var ordering: [String]
    /// The seam values replayed into this run.
    public var cassette: CassetteData
    /// What the base build did under those inputs.
    public var golden: Trace

    public init(ordering: [String], cassette: CassetteData, golden: Trace) {
        self.ordering = ordering
        self.cassette = cassette
        self.golden = golden
    }
}

/// The serializable golden-master of one scenario's explored surface — inputs *and* expected behavior,
/// in one reproducible artifact (same JSON-bundle discipline as `Trace` / `CassetteData`).
public struct ScenarioPlan: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var scenarioName: String
    /// Provenance only: the seed the recorded variants were generated with. Replay reads the stored
    /// cassettes verbatim — inputs are never re-derived, so a generator change can't skew a verdict.
    public var seed: UInt64
    /// Seams that were property-varied at record time — the domain-coverage credit a held verify earns.
    public var variedSeams: [String]
    public var probes: [ScenarioProbe]
    /// The trace-derived coverage index: class labels the golden traces exercise, extracted from the
    /// structural tier (`PromoCart.checkout` → `PromoCart`). Includes classes reached *transitively*,
    /// which is the payoff of keeping `@Traced` on — a semantic-tier-only scenario can't be scoped.
    public var coveredClasses: [String]

    public init(schemaVersion: Int = 1, scenarioName: String, seed: UInt64,
                variedSeams: [String], probes: [ScenarioProbe], coveredClasses: [String]) {
        self.schemaVersion = schemaVersion
        self.scenarioName = scenarioName
        self.seed = seed
        self.variedSeams = variedSeams
        self.probes = probes
        self.coveredClasses = coveredClasses
    }
}

// MARK: - Serialization

public extension ScenarioPlan {
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    func jsonData() throws -> Data { try Self.canonicalEncoder().encode(self) }
    func write(to url: URL) throws { try jsonData().write(to: url) }

    init(jsonData: Data) throws { self = try JSONDecoder().decode(ScenarioPlan.self, from: jsonData) }
    init(contentsOf url: URL) throws { try self.init(jsonData: Data(contentsOf: url)) }
}

// MARK: - Scope selection

public extension ScenarioPlan {
    /// The `--scope` predicate: does this plan's golden surface touch any of the changed classes?
    /// CI selects the plans worth re-running on a PR by filtering a plan catalog with this — rebuilding
    /// and replaying only scenarios whose recorded reach intersects the diff.
    func covers(anyOf changedClasses: some Sequence<String>) -> Bool {
        let changed = Set(changedClasses)
        return coveredClasses.contains(where: changed.contains)
    }
}

// MARK: - Record / verify across builds

public extension Scenario {
    /// Run this scenario's system across the whole explored surface (call orderings × seam cassettes)
    /// and pin every (input, golden trace) pair into a `ScenarioPlan`. Run on the **base** build; the
    /// first probe is the declared order under the golden cassette — the representative run.
    func record() -> ScenarioPlan {
        let recording = Cassette()
        _ = capture(make: makeSystem, order: operations, cassette: recording)
        let golden = recording.snapshot()

        let orderings = exploreOrdering ? linearExtensions(operations, max: maxOrderings) : [operations]
        let cassettes = seamDomains.isEmpty
            ? [golden]
            : golden.generatedVariants(count: ScenarioDefaults.variantCount,
                                       varying: seamDomains, seed: ScenarioDefaults.seed)

        let declaredLabels = operations.map(\.label)
        var probes = [probe(order: operations, cassette: golden)]
        for order in orderings {
            for cassette in cassettes where !(order.map(\.label) == declaredLabels && cassette == golden) {
                probes.append(probe(order: order, cassette: cassette))
            }
        }

        var classes = Set<String>()
        for probe in probes {
            for event in probe.golden.events where event.tier == .structural {
                if let dot = event.label.firstIndex(of: "."), dot != event.label.startIndex {
                    classes.insert(String(event.label[..<dot]))
                }
            }
        }
        return ScenarioPlan(scenarioName: name, seed: ScenarioDefaults.seed,
                            variedSeams: seamDomains.keys.sorted(), probes: probes,
                            coveredClasses: classes.sorted())
    }

    /// `record()` and write the plan artifact.
    @discardableResult
    func record(to url: URL) throws -> ScenarioPlan {
        let plan = record()
        try plan.write(to: url)
        return plan
    }

    /// Cross-build verify: replay every probe's recorded inputs into the **current** build's system and
    /// diff against the stored golden traces. Divergence semantics match `verify(against:)` — first
    /// divergence returns (no shrink: shrunk orderings have no recorded golden to compare against);
    /// intent-declared deltas are absorbed and the residual collateral gates. Inputs the current build
    /// can't reproduce (a renamed/removed op, a seam read past the recording) downgrade an otherwise
    /// EQUIVALENT verdict to CANNOT-VERIFY via `.unrecorded` coverage gaps.
    func verify(replaying plan: ScenarioPlan) -> ScenarioVerdict {
        let opsByLabel = Dictionary(uniqueKeysWithValues: operations.map { ($0.label, $0) })
        let planOps = orderedUnion(plan.probes.map(\.ordering))
        let missingOps = planOps.filter { opsByLabel[$0] == nil }
        let replayable = plan.probes.filter { $0.ordering.allSatisfy { opsByLabel[$0] != nil } }

        let distinctOrderings = Set(plan.probes.map(\.ordering)).count
        let variedInputs = plan.probes.contains { $0.cassette != plan.probes.first?.cassette }

        var replays: [Cassette] = []
        var representative: TraceDiff?
        for probe in replayable {
            let replay = Cassette(replaying: probe.cassette)
            let current = capture(make: makeSystem,
                                  order: probe.ordering.compactMap { opsByLabel[$0] },
                                  cassette: replay)
            let diff = BehavioralDiff.compare(baseline: probe.golden, candidate: current,
                                              tolerances: tolerances)
                .classified(against: intent)
            replays.append(replay)
            if representative == nil { representative = diff }

            guard diff.isEquivalent else {
                let coverage = coverage(replays: [replay], domainHeld: false,
                                        declaredOps: planOps, missingOps: missingOps)
                return ScenarioVerdict(result: VerificationResult(diff: diff, coverage: coverage),
                                       orderingsExplored: distinctOrderings,
                                       failingOrder: distinctOrderings > 1 ? probe.ordering : nil,
                                       counterexample: variedInputs ? probe.cassette : nil)
            }
        }

        // Every replayable probe held. Coverage decides whether that EQUIVALENT can be trusted:
        // unreplayable ops or seam misses anywhere downgrade it to CANNOT-VERIFY.
        let diff = representative ?? emptyDiff(golden: plan.scenarioName)
        let coverage = coverage(replays: replays, domainHeld: true,
                                declaredOps: planOps, missingOps: missingOps,
                                sweptSeams: plan.variedSeams)
        return ScenarioVerdict(result: VerificationResult(diff: diff, coverage: coverage),
                               orderingsExplored: distinctOrderings,
                               failingOrder: nil, counterexample: nil)
    }

    /// `verify(replaying:)` against a plan artifact on disk.
    func verify(replayingContentsOf url: URL) throws -> ScenarioVerdict {
        try verify(replaying: ScenarioPlan(contentsOf: url))
    }

    // MARK: - Machinery

    /// One golden probe: replay `cassette` into the base system on `order` and pin the trace.
    private func probe(order: [Op<S>], cassette: CassetteData) -> ScenarioProbe {
        let trace = capture(make: makeSystem, order: order, cassette: Cassette(replaying: cassette))
        return ScenarioProbe(ordering: order.map(\.label), cassette: cassette, golden: trace)
    }

    /// When *no* probe was replayable there is nothing to diff; an empty comparison stands in so the
    /// coverage gaps (every op unrecorded) can carry the CANNOT-VERIFY.
    private func emptyDiff(golden: String) -> TraceDiff {
        BehavioralDiff.compare(baseline: Trace(name: "\(golden).golden", events: []),
                               candidate: Trace(name: name, events: []),
                               tolerances: tolerances)
    }
}

/// The union of several label sequences, keeping first-seen order (deterministic gap reporting).
private func orderedUnion(_ sequences: [[String]]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for sequence in sequences {
        for label in sequence where seen.insert(label).inserted {
            result.append(label)
        }
    }
    return result
}
