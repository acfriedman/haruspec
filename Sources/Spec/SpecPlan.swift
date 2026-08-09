import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

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
public struct SpecProbe: Codable, Sendable, Equatable {
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

/// The serializable golden-master of one spec's explored surface — inputs *and* expected behavior,
/// in one reproducible artifact (same JSON-bundle discipline as `Trace` / `CassetteData`).
public struct SpecPlan: Codable, Sendable, Equatable {
    /// The one plan schema this engine writes and replays. `init(jsonData:)` rejects anything else —
    /// a stale shape whose field names happen to still decode would replay garbage with confidence.
    ///
    /// Bumped to 2 when `Scenario` became `Spec`: the plan's `scenarioName` key is now `specName`,
    /// so a version-1 artifact must be re-recorded rather than coerced. Bumped to 3 when a trace
    /// event's `thread` (a first-seen `worker-N`) became a nominal `domain` — a version-2 artifact
    /// names threads that no longer exist as a concept. Bumped to 4 when `pool` became `ambient`: a
    /// version-3 artifact records where unisolated work *landed*, which the resolver no longer treats
    /// as a fact about the subject. Without the bump those plans fail on an unrecognized spelling
    /// rather than on the one message that helps — re-record. Bumped to 5 when events began carrying
    /// `spawnedBy`: a version-4 plan has no happens-before edges, and a replay against one would read
    /// their absence as the subject having stopped spawning work.
    public static let supportedSchemaVersion = 6

    public var schemaVersion: Int
    public var specName: String
    /// Provenance only: the seed the recorded variants were generated with. Replay reads the stored
    /// cassettes verbatim — inputs are never re-derived, so a generator change can't skew a verdict.
    public var seed: UInt64
    /// Seams that were property-varied at record time — the domain-coverage credit a held verify earns.
    public var variedSeams: [String]
    public var probes: [SpecProbe]
    /// The trace-derived coverage index: class labels the golden traces exercise, extracted from the
    /// structural tier (`PromoCart.checkout` → `PromoCart`). Includes classes reached *transitively*,
    /// which is the payoff of keeping `@Traced` on — a semantic-tier-only spec can't be scoped.
    public var coveredClasses: [String]

    public init(
        schemaVersion: Int = SpecPlan.supportedSchemaVersion,
        specName: String,
        seed: UInt64,
        variedSeams: [String],
        probes: [SpecProbe],
        coveredClasses: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.specName = specName
        self.seed = seed
        self.variedSeams = variedSeams
        self.probes = probes
        self.coveredClasses = coveredClasses
    }
}

/// Just the version field, so a plan can be gated before anything else about its shape is assumed.
private struct SchemaStamp: Decodable {
    let schemaVersion: Int
}

/// Thrown when a plan artifact can't be trusted for replay. Fail-fast at the decode boundary: the
/// alternative — replaying whatever fields still line up — is a verdict built on unversioned input.
public enum SpecPlanError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, supported):
            "unsupported plan schemaVersion \(found) (this engine replays \(supported)) — "
                + "re-record the plan with the current engine"
        }
    }
}

// MARK: - Serialization

public extension SpecPlan {
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    func jsonData() throws -> Data {
        try Self.canonicalEncoder().encode(self)
    }

    /// A `.gz` destination opts into deterministic gzip (canonical pretty JSON inside), turning the
    /// multi-megabyte plan into a few hundred committed kilobytes. Anything else writes plain JSON.
    func write(to url: URL) throws {
        if url.pathExtension == "gz" {
            try Gzip.compress(jsonData()).write(to: url)
        } else {
            try jsonData().write(to: url)
        }
    }

    init(jsonData: Data) throws {
        // Version first, on its own: an artifact from an older schema may no longer decode into this
        // shape at all, and "re-record the plan" is the answer a caller needs — not a keyNotFound.
        let stamp = try JSONDecoder().decode(SchemaStamp.self, from: jsonData)
        guard stamp.schemaVersion == Self.supportedSchemaVersion else {
            throw SpecPlanError.unsupportedSchemaVersion(
                found: stamp.schemaVersion,
                supported: Self.supportedSchemaVersion
            )
        }
        self = try JSONDecoder().decode(SpecPlan.self, from: jsonData)
    }

    /// Reads plain or gzipped plans alike — detection is by content (the gzip magic), not filename,
    /// so a renamed artifact still replays.
    init(contentsOf url: URL) throws {
        let raw = try Data(contentsOf: url)
        try self.init(jsonData: Gzip.isGzip(raw) ? Gzip.decompress(raw) : raw)
    }
}

// MARK: - Scope selection

public extension SpecPlan {
    /// The `--scope` predicate: does this plan's golden surface touch any of the changed classes?
    /// CI selects the plans worth re-running on a PR by filtering a plan catalog with this — rebuilding
    /// and replaying only specs whose recorded reach intersects the diff.
    func covers(anyOf changedClasses: some Sequence<String>) -> Bool {
        let changed = Set(changedClasses)
        return coveredClasses.contains(where: changed.contains)
    }
}

// MARK: - Record / verify across builds

public extension Spec {
    /// Run this spec's system across the whole explored surface (call orderings × seam cassettes)
    /// and pin every (input, golden trace) pair into a `SpecPlan`. Run on the **base** build; the
    /// first probe is the declared order under the golden cassette — the representative run.
    func record() async -> SpecPlan {
        let recording = Cassette()
        _ = await capture(make: makeSystem, order: explorationOrder(), cassette: recording)
        let golden = recording.snapshot()

        // The same resolved surface `verify(against:)` explores — one budget, spent identically on
        // both sides of the build boundary, so the plan's size is the dial the author declared.
        let plan = explorationPlan(golden: golden)

        let declaredLabels = operations.map(\.label)
        var probes = await [probe(order: operations, cassette: golden)]
        for (index, order) in plan.orderings.enumerated() {
            for cassette in plan.cassettes(forOrdering: index)
                where !(order.map(\.label) == declaredLabels && cassette == golden) {
                await probes.append(probe(order: order, cassette: cassette))
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
        return SpecPlan(
            specName: name,
            seed: SpecDefaults.seed,
            variedSeams: seamDomains.keys.sorted(),
            probes: probes,
            coveredClasses: classes.sorted()
        )
    }

    /// `record()` and write the plan artifact.
    @discardableResult
    func record(to url: URL) async throws -> SpecPlan {
        let plan = await record()
        try plan.write(to: url)
        return plan
    }

    /// Cross-build verify: replay every probe's recorded inputs into the **current** build's system and
    /// diff against the stored golden traces. Divergence semantics match `verify(against:)` — first
    /// divergence returns (no shrink: shrunk orderings have no recorded golden to compare against);
    /// intent-declared deltas are absorbed and the residual collateral gates. Inputs the current build
    /// can't reproduce (a renamed/removed op, a seam read past the recording) downgrade an otherwise
    /// EQUIVALENT verdict to CANNOT-VERIFY via `.unrecorded` coverage gaps.
    func verify(replaying plan: SpecPlan, declaring intent: Intent = .none) async -> SpecVerdict {
        let opsByLabel = Dictionary(uniqueKeysWithValues: operations.map { ($0.label, $0) })
        let planOps = orderedUnion(plan.probes.map(\.ordering))
        let missingOps = planOps.filter { opsByLabel[$0] == nil }
        let replayable = plan.probes.filter { $0.ordering.allSatisfy { opsByLabel[$0] != nil } }

        let distinctOrderings = Set(plan.probes.map(\.ordering)).count
        let variedInputs = plan.probes.contains { $0.cassette != plan.probes.first?.cassette }
        let exploration = exploration(recordedIn: plan)

        var replays: [Cassette] = []
        var representative: TraceDiff?
        for probe in replayable {
            let replay = Cassette(replaying: probe.cassette)
            let current = await capture(
                make: makeSystem,
                order: probe.ordering.compactMap { opsByLabel[$0] },
                cassette: replay
            )
            let diff = BehavioralDiff.compare(
                baseline: probe.golden,
                candidate: current,
                tolerances: tolerances
            )
            .classified(against: intent)
            replays.append(replay)
            if representative == nil {
                representative = diff
            }

            guard diff.isEquivalent else {
                let coverage = coverage(
                    replays: [replay],
                    domainHeld: false,
                    declaredOps: planOps,
                    missingOps: missingOps
                )
                return SpecVerdict(
                    result: VerificationResult(diff: diff, coverage: coverage),
                    orderingsExplored: distinctOrderings,
                    failingOrder: distinctOrderings > 1 ? probe.ordering : nil,
                    counterexample: variedInputs ? probe.cassette : nil,
                    exploration: exploration,
                    violatedPreconditions: distinctOrderings > 1
                        ? preconditionViolations(in: probe.ordering)
                        : nil
                )
            }
        }

        // Every replayable probe held. Coverage decides whether that EQUIVALENT can be trusted:
        // unreplayable ops or seam misses anywhere downgrade it to CANNOT-VERIFY.
        let diff = representative ?? emptyDiff(golden: plan.specName)
        let coverage = coverage(
            replays: replays,
            domainHeld: true,
            declaredOps: planOps,
            missingOps: missingOps,
            sweptSeams: plan.variedSeams
        )
        return SpecVerdict(
            result: VerificationResult(diff: diff, coverage: coverage),
            orderingsExplored: distinctOrderings,
            failingOrder: nil,
            counterexample: nil,
            exploration: exploration
        )
    }

    /// `verify(replaying:)` against a plan artifact on disk.
    func verify(replayingContentsOf url: URL, declaring intent: Intent = .none) async throws -> SpecVerdict {
        try await verify(replaying: SpecPlan(contentsOf: url), declaring: intent)
    }

    // MARK: - Machinery

    /// What the recorded plan covered, read through the surface the *current* build declares: the plan
    /// pins the orderings that were explored, but the denominator — and whether an ordering counts as
    /// out-of-order — comes from this build's constraints, so a replay reports the same fraction a live
    /// verify would, and a spec that softened an `.after` since recording says so.
    private func exploration(recordedIn plan: SpecPlan) -> Exploration {
        let orderings = Set(plan.probes.map(\.ordering))
        let available = exploreOrdering
            ? countLinearExtensions(operations, repeating: orderingRepeats, limit: SpecDefaults.orderingCountLimit)
            : (count: 1, exact: true)
        return Exploration(
            orderingsExplored: orderings.count,
            orderingsAvailable: Swift.max(available.count, orderings.count),
            orderingsAreExact: available.exact,
            variantsPerOrdering: Swift.max(1, plan.probes.count / Swift.max(1, orderings.count)),
            outOfOrderExplored: outOfOrderCount(among: Array(orderings))
        )
    }

    /// One golden probe: replay `cassette` into the base system on `order` and pin the trace.
    private func probe(order: [Op<S>], cassette: CassetteData) async -> SpecProbe {
        let trace = await capture(make: makeSystem, order: order, cassette: Cassette(replaying: cassette))
        return SpecProbe(ordering: order.map(\.label), cassette: cassette, golden: trace)
    }

    /// When *no* probe was replayable there is nothing to diff; an empty comparison stands in so the
    /// coverage gaps (every op unrecorded) can carry the CANNOT-VERIFY.
    private func emptyDiff(golden: String) -> TraceDiff {
        BehavioralDiff.compare(
            baseline: Trace(name: "\(golden).golden", events: []),
            candidate: Trace(name: name, events: []),
            tolerances: tolerances
        )
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
