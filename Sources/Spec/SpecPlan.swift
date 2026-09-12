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
    /// Bumped to 2 when `Scenario` became `Spec`: the plan's `scenarioName` key became `specName`,
    /// so a version-1 artifact must be re-recorded rather than coerced. Bumped to 3 when a trace
    /// event's `thread` (a first-seen `worker-N`) became a nominal `domain` — a version-2 artifact
    /// names threads that no longer exist as a concept. Bumped to 4 when `pool` became `ambient`: a
    /// version-3 artifact records where unisolated work *landed*, which the resolver no longer treats
    /// as a fact about the subject. Without the bump those plans fail on an unrecognized spelling
    /// rather than on the one message that helps — re-record. Bumped to 5 when events began carrying
    /// `spawnedBy`: a version-4 plan has no happens-before edges, and a replay against one would read
    /// their absence as the subject having stopped spawning work. Bumped to 6 when a queue domain
    /// gained its ordering discipline (`queue(serial):` / `queue(concurrent):`). Bumped to 7 when
    /// property capture landed: goldens now carry `.stateChange` / `.snapshot` events and a
    /// `mutationCapture` stamp — a version-6 plan's silence about writes would read as the subject
    /// never writing.
    public static let supportedSchemaVersion = 7

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

    /// The record-on-merge freshness stamp (`PlanProvenance`), or `nil` for a plan recorded
    /// outside the reconciler.
    ///
    /// Absence is meaningful — an unstamped plan sweeps as stale — so this is a genuine optional,
    /// not a migration decoder, and adding it did not bump the plan schema.
    public var provenance: PlanProvenance?

    public init(
        schemaVersion: Int = SpecPlan.supportedSchemaVersion,
        specName: String,
        seed: UInt64,
        variedSeams: [String],
        probes: [SpecProbe],
        coveredClasses: [String],
        provenance: PlanProvenance? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.specName = specName
        self.seed = seed
        self.variedSeams = variedSeams
        self.probes = probes
        self.coveredClasses = coveredClasses
        self.provenance = provenance
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
    /// The scope predicate: does this plan's golden surface touch any of the changed classes?
    /// CI selects the plans worth re-running on a PR by filtering a plan catalog with this — rebuilding
    /// and replaying only specs whose recorded reach intersects the diff.
    func covers(anyOf changedClasses: some Sequence<String>) -> Bool {
        let changed = Set(changedClasses)
        return coveredClasses.contains(where: changed.contains)
    }
}

// MARK: - Record / verify across builds

public extension Spec {
    /// Runs this spec's system across the whole explored surface (call orderings × seam cassettes)
    /// and pins every (input, golden trace) pair into a `SpecPlan`. Run on the **base** build; the
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

        return SpecPlan(
            specName: name,
            seed: SpecDefaults.seed,
            // The plan's, not the declaration's: packaged resource sweeps the golden earned are part
            // of the varied surface a replay reports.
            variedSeams: plan.domains.keys.sorted(),
            probes: probes,
            coveredClasses: structuralClasses(in: probes.map(\.golden))
        )
    }

    /// `record()` and writes the plan artifact.
    @discardableResult
    func record(to url: URL) async throws -> SpecPlan {
        let plan = await record()
        try plan.write(to: url)
        return plan
    }

    /// Cross-build verify: replays every probe's recorded inputs into the **current** build's system and
    /// diffs against the stored golden traces. Divergence semantics match `verify(against:)` — first
    /// divergence returns (no shrink: shrunk orderings have no recorded golden to compare against);
    /// intent-declared deltas are absorbed and the residual collateral gates. Inputs the current build
    /// can't reproduce (a renamed/removed op, a seam read past the recording) downgrade an otherwise
    /// EQUIVALENT verdict to CANNOT-VERIFY via `.unrecorded` coverage gaps.
    ///
    /// The whole replay runs `replays` times (see `Stability.defaultReplays`), and every pass must
    /// reach the same verdict with the same divergence inventory — disagreement flips the verdict to
    /// UNSTABLE and carries the run-to-run delta rather than either pass (see `Stability`). The
    /// passes are sequential and share nothing but the immutable plan; run 1's verdict is the
    /// representative the artifact keeps.
    func verify(
        replaying plan: SpecPlan,
        declaring intent: Intent = .none,
        replays: Int = Stability.defaultReplays
    ) async -> SpecVerdict {
        precondition(replays >= 1, "verify(replaying:) needs at least one replay pass, got \(replays)")
        return await collectingOrigins(declaring: intent) {
            var passes: [SpecVerdict] = []
            for _ in 0 ..< replays {
                await passes.append(verifyOnce(replaying: plan, declaring: intent))
            }
            return passes[0].qualified(by: .measured(over: passes))
        }
    }

    /// One replay pass — the primitive `verify(replaying:)` repeats and compares.
    private func verifyOnce(replaying plan: SpecPlan, declaring intent: Intent) async -> SpecVerdict {
        let surface = replaySurface(of: plan)

        var replays: [Cassette] = []
        var representative: TraceDiff?
        var sweep = IntentSweep()
        for probe in surface.replayable {
            let replay = Cassette(replaying: probe.cassette)
            let current = await capture(
                make: makeSystem,
                order: probe.ordering.compactMap { surface.opsByLabel[$0] },
                cassette: replay
            )
            var diff = BehavioralDiff.compare(
                baseline: probe.golden,
                candidate: current,
                tolerances: effectiveTolerances
            )
            .classified(against: intent, inputs: probe.cassette.tracks)
            sweep.observe(diff)
            replays.append(replay)
            if representative == nil {
                representative = diff
            }

            guard diff.isEquivalent else {
                // A sweep that stopped here walked only part of the surface: it cannot claim any
                // declaration matched nothing, so the diverged verdict makes no unobserved claim.
                diff.unobservedIntent = []
                return divergedReplayVerdict(diff: diff, probe: probe, replay: replay, surface: surface)
            }
        }

        // Every replayable probe held. Coverage decides whether that EQUIVALENT can be trusted:
        // unreplayable ops or seam misses anywhere downgrade it to CANNOT-VERIFY.
        // Zero replayable probes observed nothing, so classifying the empty diff reads back the
        // whole declaration list as unobserved.
        let diff = sweep.settle(representative ?? emptyDiff(golden: plan.specName).classified(against: intent))
        let coverage = coverage(
            replays: replays,
            domainHeld: true,
            declaredOps: surface.planOps,
            missingOps: surface.missingOps,
            sweptSeams: plan.variedSeams
        )
        return SpecVerdict(
            result: VerificationResult(diff: diff, coverage: coverage),
            orderingsExplored: surface.distinctOrderings,
            failingOrder: nil,
            counterexample: nil,
            exploration: surface.exploration,
            qualification: surface.qualification
        )
    }

    /// Sweep-wide intent bookkeeping shared by the replay and live verify loops: a sweep compares
    /// many probes but reports one diff, and intent facts are sweep-wide, not per-probe.
    ///
    /// Two corrections it applies to the reported diff:
    ///  - **disclosure** — a green-by-declaration verdict must show what it absorbed, and the
    ///    reported probe may be clean while a later probe carried the change; the first absorbing
    ///    diff is preferred.
    ///  - **unobserved intersection** — a declaration is observed if ANY probe matched it, so the
    ///    sweep-wide unobserved set is the intersection of the per-probe ones.
    struct IntentSweep {
        private var intendedRepresentative: TraceDiff?
        private var unobservedAcross: Set<String>?

        mutating func observe(_ diff: TraceDiff) {
            unobservedAcross = unobservedAcross
                .map { $0.intersection(diff.unobservedIntent) } ?? Set(diff.unobservedIntent)
            if intendedRepresentative == nil, diff.intendedCount > 0 {
                intendedRepresentative = diff
            }
        }

        /// The diff the verdict should carry: the first absorbing diff when one exists (else
        /// `fallback`), its unobserved list corrected to the sweep-wide intersection.
        func settle(_ fallback: TraceDiff) -> TraceDiff {
            var diff = intendedRepresentative ?? fallback
            if let unobservedAcross {
                diff.unobservedIntent = diff.unobservedIntent.filter(unobservedAcross.contains)
            }
            return diff
        }
    }

    /// The first-divergence exit: stops, and pins the probe that exposed it.
    private func divergedReplayVerdict(
        diff: TraceDiff,
        probe: SpecProbe,
        replay: Cassette,
        surface: ReplaySurface<S>
    ) -> SpecVerdict {
        let coverage = coverage(
            replays: [replay],
            domainHeld: false,
            declaredOps: surface.planOps,
            missingOps: surface.missingOps
        )
        return SpecVerdict(
            result: VerificationResult(diff: diff, coverage: coverage),
            orderingsExplored: surface.distinctOrderings,
            failingOrder: surface.distinctOrderings > 1 ? probe.ordering : nil,
            counterexample: surface.variedInputs ? probe.cassette : nil,
            exploration: surface.exploration,
            qualification: surface.qualification,
            violatedPreconditions: surface.distinctOrderings > 1
                ? preconditionViolations(in: probe.ordering)
                : nil
        )
    }

    /// `verify(replaying:)` against a plan artifact on disk.
    func verify(
        replayingContentsOf url: URL,
        declaring intent: Intent = .none,
        replays: Int = Stability.defaultReplays
    ) async throws -> SpecVerdict {
        try await verify(replaying: SpecPlan(contentsOf: url), declaring: intent, replays: replays)
    }

    // MARK: - Machinery

    /// One golden probe: replays `cassette` into the base system on `order` and pins the trace.
    private func probe(order: [Op<S>], cassette: CassetteData) async -> SpecProbe {
        let trace = await capture(make: makeSystem, order: order, cassette: Cassette(replaying: cassette))
        return SpecProbe(ordering: order.map(\.label), cassette: cassette, golden: trace)
    }
}
