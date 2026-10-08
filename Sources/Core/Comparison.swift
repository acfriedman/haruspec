import Foundation

/// How the structural (auto-captured) tier participates in the verdict.
///
/// Mechanical migrations don't rename, so structural is the contract (`strict`, the default). A
/// rename-heavy refactor gates on the semantic tier instead, treating structural divergences as
/// `advisory` (reported, non-failing) or `ignored` (dropped entirely).
public enum StructuralComparison: String, Codable, Sendable {
    case strict // structural divergences fail the verdict
    case advisory // structural divergences are reported but do not fail the verdict
    case ignored // structural events are dropped; only semantic events are compared
}

/// How an event that ran on a *different isolation domain* participates in the verdict.
///
/// Default `.gating`, **red until declared**: a domain move is a real behavioral change — different
/// re-entrancy, different observers' threads, different subtle bugs — so an undeclared one fails the
/// verdict, and the intended one is a one-line ``Intent/expectedDomainMigrations`` declaration.
/// `.advisory` reports without failing; `.ignored` turns detection off, where a moved
/// event reads as a missing + unexpected pair.
public enum DomainMigrationPolicy: String, Codable, Sendable {
    case advisory // reported, does not fail the verdict
    case gating // an undeclared domain change fails the verdict
    case ignored // not detected; a migrated event reads as a missing/unexpected pair
}

/// How concurrent traces are compared.
///
/// A trace is recorded as one total order, but for concurrent code the interleaving is a property of
/// the *scheduler*: two runs of an unchanged binary produce different orders, and comparing them as
/// sequences manufactures a different counterexample every run. `.perDomain` stops comparing the one
/// interleaving and compares per-domain projections instead:
///
///  - an **ordered** domain (main / actor / serial queue) keeps the sequence comparison — its order
///    is a runtime guarantee, so it stays a contract;
///  - a bucket with **no meaningful internal order** (concurrent queue, `ambient`) is compared as a
///    **multiset** — which effects, with which payloads, how many times;
///  - **cross-domain** relative order is dropped entirely;
///  - an ordered baseline domain whose events land in an unordered candidate domain is compared as a
///    multiset (either side unordered ⇒ multiset — losing an assertion rather than inventing one),
///    and the dropped guarantee itself is reported as `orderingRelaxed`, which **gates** until the
///    change declares it via ``Intent/expectedOrderingRelaxations``.
public enum ConcurrencyComparison: String, Codable, Sendable {
    case totalOrder // compare the recorded interleaving as one sequence
    case perDomain // project by domain: ordered ⇒ sequence, unordered ⇒ multiset, cross-domain order dropped
}

/// How the recorded spawn edges participate in the verdict.
///
/// The edge pass compares happens-before *constraints* (see `DiffSpawnEdges.swift`): a baseline
/// constraint the candidate can no longer prove is `orderingLost` — a dropped synchronization,
/// detected structurally from a passing run — and the reverse is `orderingAdded`, the awaited port
/// of fire-and-forget work. Default `.gating`, **red until declared**
/// (``Intent/expectedOrderingLosses`` / ``Intent/expectedOrderingAdditions``): both are real behavioral
/// changes. Known cost, accepted deliberately: the pass does not chase transitive chains, so a
/// constraint preserved through an intermediate hop over-reports — a spec hitting that drops to
/// `.advisory`, and the over-report rate on real subjects is an open measurement.
public enum SpawnEdgePolicy: String, Codable, Sendable {
    case advisory // constraint changes are reported, but do not fail the verdict
    case gating // an undeclared constraint change fails the verdict
    case ignored // spawn edges are not compared at all
}

/// How two traces are compared: which differences count as behavior. Anything the comparison does
/// not set aside is a divergence.
///
/// It sets aside what is not behavior: floating-point jitter, timing within a budget, the order of
/// independent effects, channels opted out. It has no way to set aside a value the subject makes up
/// itself (a fresh UUID, a wall-clock reading): that is an uncontrolled seam, controlled by injecting
/// its source, and a run that varies on one reads as UNSTABLE. Loadable from JSON so an application
/// ships its own.
public struct Comparison: Sendable, Equatable {
    /// Absolute epsilon for numeric comparisons, absorbing floating-point jitter.
    public var numericEpsilon: Double

    /// The allowed *increase* in `durationTicks` per event label. A label with no budget has no
    /// timing compared, and one with a budget flags any regression beyond it.
    public var timingBudgets: [String: Int64]

    /// Groups of labels whose relative order is not significant. A reordering confined to a group is
    /// not a divergence (e.g. two independent notifications posted in either order).
    public var unorderedGroups: [[String]]

    /// Event kinds to drop entirely before diffing (e.g. noisy internal `.custom` telemetry).
    public var ignoredKinds: [EventKind]

    /// Notification names whose `.notification` events are dropped from both sides at diff time,
    /// leaving the raw trace faithful. Specs capture *all* notifications by default, so this is the
    /// opt-out for one noisy channel: ``ignoredKinds`` scoped by name rather than kind.
    public var ignoredNotificationNames: [String]

    /// How the structural (auto-captured) tier participates in the verdict. Defaults to `.strict`.
    public var structuralComparison: StructuralComparison

    /// How an event that moved isolation domains participates in the verdict. Defaults to `.gating`
    /// (red until declared via ``Intent/expectedDomainMigrations``).
    public var domainMigration: DomainMigrationPolicy

    /// How concurrent traces are compared. Defaults to `.totalOrder`; a spec whose subject does
    /// genuinely parallel work opts into `.perDomain`, where scheduler interleaving stops being
    /// treated as behavior.
    public var concurrency: ConcurrencyComparison

    /// How spawn-edge constraint changes participate in the verdict. Defaults to `.gating`
    /// (red until declared via ``Intent/expectedOrderingLosses`` / ``Intent/expectedOrderingAdditions``).
    public var spawnEdges: SpawnEdgePolicy

    public init(
        numericEpsilon: Double = 0,
        timingBudgets: [String: Int64] = [:],
        unorderedGroups: [[String]] = [],
        ignoredKinds: [EventKind] = [],
        ignoredNotificationNames: [String] = [],
        structuralComparison: StructuralComparison = .strict,
        domainMigration: DomainMigrationPolicy = .gating,
        concurrency: ConcurrencyComparison = .totalOrder,
        spawnEdges: SpawnEdgePolicy = .gating
    ) {
        self.numericEpsilon = numericEpsilon
        self.timingBudgets = timingBudgets
        self.unorderedGroups = unorderedGroups
        self.ignoredKinds = ignoredKinds
        self.ignoredNotificationNames = ignoredNotificationNames
        self.structuralComparison = structuralComparison
        self.domainMigration = domainMigration
        self.concurrency = concurrency
        self.spawnEdges = spawnEdges
    }

    /// Exact match on everything. The recorder already removes the nondeterminism of capture itself
    /// (addresses, threads, wall time); everything left is behavior.
    public static let strict = Comparison()
}

extension Comparison: Codable {
    enum CodingKeys: String, CodingKey {
        case numericEpsilon, timingBudgets, unorderedGroups, ignoredKinds
        case ignoredNotificationNames, structuralComparison, domainMigration, concurrency, spawnEdges
    }

    /// Keys a comparison no longer reads, each of which fails decoding with what replaced it.
    enum RetiredKeys: String, CodingKey { case volatileFields }

    /// Every field is optional in JSON so a partial comparison is ergonomic. A `volatileFields` key
    /// throws rather than being skipped: a file that relied on redaction would otherwise read as
    /// stricter than its author meant, with no word on why.
    public init(from decoder: Decoder) throws {
        let retired = try decoder.container(keyedBy: RetiredKeys.self)
        if retired.contains(.volatileFields) {
            throw DecodingError.dataCorruptedError(
                forKey: .volatileFields,
                in: retired,
                debugDescription: "volatileFields is retired: a value the subject makes up (a UUID, a clock "
                    + "reading) is an uncontrolled seam — inject its source instead of redacting it"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        numericEpsilon = try container.decodeIfPresent(Double.self, forKey: .numericEpsilon) ?? 0
        timingBudgets = try container.decodeIfPresent([String: Int64].self, forKey: .timingBudgets) ?? [:]
        unorderedGroups = try container.decodeIfPresent([[String]].self, forKey: .unorderedGroups) ?? []
        ignoredKinds = try container.decodeIfPresent([EventKind].self, forKey: .ignoredKinds) ?? []
        ignoredNotificationNames = try container.decodeIfPresent([String].self, forKey: .ignoredNotificationNames) ?? []
        structuralComparison = try container
            .decodeIfPresent(StructuralComparison.self, forKey: .structuralComparison) ?? .strict
        domainMigration = try container
            .decodeIfPresent(DomainMigrationPolicy.self, forKey: .domainMigration) ?? .gating
        concurrency = try container
            .decodeIfPresent(ConcurrencyComparison.self, forKey: .concurrency) ?? .totalOrder
        spawnEdges = try container
            .decodeIfPresent(SpawnEdgePolicy.self, forKey: .spawnEdges) ?? .gating
    }
}

public extension Comparison {
    /// Loads a comparison from a JSON file, so an application can ship its own.
    ///
    /// - Parameter url: The file to read.
    /// - Throws: Any error reading `url`, or a `DecodingError` when its contents are not a
    ///   comparison or carry the retired `volatileFields`.
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Comparison.self, from: Data(contentsOf: url))
    }

    /// Whether a label belongs to any unordered group.
    ///
    /// - Parameter label: The event label.
    /// - Returns: `true` when some group in ``unorderedGroups`` names it.
    func isUnordered(label: String) -> Bool {
        unorderedGroups.contains { $0.contains(label) }
    }

    /// Returns the timing budget declared for a label.
    ///
    /// - Parameter label: The event label.
    /// - Returns: The allowed increase in ticks, or `nil` when the label's timing is not compared.
    func timingBudget(for label: String) -> Int64? {
        timingBudgets[label]
    }
}
