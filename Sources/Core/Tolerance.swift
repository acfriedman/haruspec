import Foundation

/// The declared "acceptable behavioral delta" between two traces.
///
/// The *tolerance model*: the contract that separates a real behavioral change from
/// inherent run-to-run noise (fresh UUIDs, clock jitter, order-insensitive side effects). Anything
/// not explicitly tolerated is a divergence. Loadable from JSON so applications ship their own specs.
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

/// One payload field whose value is non-deterministic and must be redacted before comparison.
///
/// Constructed only through the typed factories, so an ill-formed rule is unrepresentable:
///  - `.key("orderID")` — matched by name at any depth, in any event.
///  - `.key("id", inEvent: "checkout")` — same, but only in events with that label. Use this when
///    one name means different things in different events (a fresh UUID in `checkout`, a stable
///    identifier in `addItem`) so redaction can't swallow a real divergence.
///  - `.path("receipt.issuedAt")` — an exact position in the payload tree, dotted, one component
///    per object key (also scopable with `inEvent:`). Malformed paths trap at construction. `.` is
///    the separator, so a key literally containing one is only addressable via `.key`.
public struct VolatileField: Sendable, Equatable, Hashable {
    /// Where in the payload tree the rule points.
    public enum Position: Sendable, Equatable, Hashable {
        /// A key matched by name at any depth.
        case key(String)
        /// The exact route from the payload root, one component per object key. Arrays are
        /// transparent — elements contribute no component, so one path addresses the field in
        /// every element. Non-empty by construction.
        case path([String])
    }

    public let position: Position

    /// The event label this rule is confined to; `nil` applies to every event.
    public let label: String?

    private init(position: Position, label: String?) {
        self.position = position
        self.label = label
    }

    /// A key matched by name at any depth, optionally confined to events with `label`.
    public static func key(_ key: String, inEvent label: String? = nil) -> VolatileField {
        VolatileField(position: .key(key), label: label)
    }

    /// An exact payload position as a dotted route from the root, e.g. `"receipt.issuedAt"`,
    /// optionally confined to events with `label`. Traps on an empty or dot-mangled path so a
    /// mistyped rule fails at construction, not by silently never matching.
    public static func path(_ dotted: String, inEvent label: String? = nil) -> VolatileField {
        guard let components = parsePath(dotted) else {
            preconditionFailure("volatile path \"\(dotted)\" must be dot-separated non-empty components")
        }
        return VolatileField(position: .path(components), label: label)
    }

    /// `nil` unless every dot-separated component is non-empty (rejects `""`, `".a"`, `"a..b"`…).
    static func parsePath(_ dotted: String) -> [String]? {
        let components = dotted.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return components.contains("") ? nil : components
    }

    /// Whether this rule redacts the field named `key` at `path` (root-to-field, inclusive) inside
    /// an event labeled `label`.
    public func matches(key candidateKey: String, label candidateLabel: String, path candidatePath: [String]) -> Bool {
        if let label, label != candidateLabel {
            return false
        }
        switch position {
        case let .key(key): return key == candidateKey
        case let .path(path): return path == candidatePath
        }
    }
}

/// How an event that ran on a *different isolation domain* participates in the verdict.
///
/// Default `.gating`, **red until declared**: a domain move is a real behavioral change — different
/// re-entrancy, different observers' threads, different subtle bugs — so an undeclared one fails the
/// verdict, and the intended one is a one-line `Intent.expectedDomainMigrations` declaration. (An
/// earlier default of `.advisory` reasoned that a migration moves every event, so gating is red by
/// construction — but that was really "red with no exit," and the declaration is the exit.)
/// `.advisory` reports without failing; `.ignored` restores the pre-migration reading, where a moved
/// event is a missing + unexpected pair.
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
///    change declares it via `Intent.expectedOrderingRelaxations`.
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
/// (`Intent.expectedOrderingLosses` / `expectedOrderingAdditions`): both are real behavioral
/// changes. Known cost, accepted deliberately: the pass does not chase transitive chains, so a
/// constraint preserved through an intermediate hop over-reports — a spec hitting that drops to
/// `.advisory`, and the over-report rate on real subjects is an open measurement.
public enum SpawnEdgePolicy: String, Codable, Sendable {
    case advisory // constraint changes are reported, but do not fail the verdict
    case gating // an undeclared constraint change fails the verdict
    case ignored // spawn edges are not compared at all
}

/// How the *order* of observed property writes (`.stateChange` events) participates in the verdict.
///
/// Default `.advisory` — deliberately weaker than the safe-by-default gates, and deliberately
/// temporary: intermediate write order is contract **iff something observes the property between
/// writes** (KVO / Combine / SwiftUI), and until subscriptions are traced the engine cannot know.
/// Gating every port on internal write order would fail refactors no observer can distinguish.
/// The end-state *values* still gate unconditionally through `.snapshot` events, so advisory here
/// never waives the state contract — only the timeline. A spec whose subject is known-observed opts
/// up to `.gating`, where an intended reorder declares itself via `Intent` (`Reorders(_:)`).
public enum MutationOrderPolicy: String, Codable, Sendable {
    case advisory // write-order divergences are reported, but do not fail the verdict
    case gating // an undeclared write-order change fails the verdict
    case ignored // `.stateChange` events are dropped before diffing
}

public struct Tolerance: Sendable, Equatable {
    /// Payload fields whose values are non-deterministic and must be ignored — e.g.
    /// `.key("orderID")`. Redacted to a placeholder before comparison. See `VolatileField` for the
    /// scoping options (`inEvent:`, `.path`).
    public var volatileFields: [VolatileField]

    /// Absolute epsilon for numeric comparisons, absorbing floating-point jitter.
    public var numericEpsilon: Double

    /// Per-label allowed *increase* in `durationTicks`, keyed by event label. Absent ⇒ timing for
    /// that label is fully tolerant (ignored). Present ⇒ a regression beyond the budget is flagged.
    public var timingBudgets: [String: Int64]

    /// Groups of labels whose relative order is not significant. A reordering confined to a group is
    /// tolerated (e.g. two independent notifications posted in either order).
    public var unorderedGroups: [[String]]

    /// Event kinds to drop entirely before diffing (e.g. noisy internal `.custom` telemetry).
    public var ignoredKinds: [EventKind]

    /// Notification names to drop before diffing. Since specs capture *all* notifications by
    /// default, this is the opt-out for a specific noisy channel: it removes matching `.notification`
    /// events from both sides at diff time, leaving the raw trace faithful. Mirrors `ignoredKinds` but
    /// scoped by name rather than kind.
    public var ignoredNotificationNames: [String]

    /// How the structural (auto-captured) tier participates in the verdict. Defaults to `.strict`.
    public var structuralComparison: StructuralComparison

    /// How an event that moved isolation domains participates in the verdict. Defaults to `.gating`
    /// (red until declared via `Intent.expectedDomainMigrations`).
    public var domainMigration: DomainMigrationPolicy

    /// How concurrent traces are compared. Defaults to `.totalOrder`; a spec whose subject does
    /// genuinely parallel work opts into `.perDomain`, where scheduler interleaving stops being
    /// treated as behavior.
    public var concurrency: ConcurrencyComparison

    /// How spawn-edge constraint changes participate in the verdict. Defaults to `.gating`
    /// (red until declared via `Intent.expectedOrderingLosses` / `expectedOrderingAdditions`).
    public var spawnEdges: SpawnEdgePolicy

    /// How observed-property write order participates in the verdict. Defaults to `.advisory`
    /// (see `MutationOrderPolicy` — snapshots gate the values regardless).
    public var mutationOrder: MutationOrderPolicy

    /// The `.stateChange` labels this comparison is *about* — the boundary protocol's properties,
    /// fully qualified (`"Cart.itemCount"`). Writes to anything else (a port's private state) are
    /// dropped at diff time so internals never manufacture divergences; the raw trace stays faithful.
    /// `nil` means unscoped — every recorded write compares — which is the raw-diff default; a spec
    /// always scopes (possibly to nothing).
    public var observedStateLabels: [String]?

    public init(
        volatileFields: [VolatileField] = [],
        numericEpsilon: Double = 0,
        timingBudgets: [String: Int64] = [:],
        unorderedGroups: [[String]] = [],
        ignoredKinds: [EventKind] = [],
        ignoredNotificationNames: [String] = [],
        structuralComparison: StructuralComparison = .strict,
        domainMigration: DomainMigrationPolicy = .gating,
        concurrency: ConcurrencyComparison = .totalOrder,
        spawnEdges: SpawnEdgePolicy = .gating,
        mutationOrder: MutationOrderPolicy = .advisory,
        observedStateLabels: [String]? = nil
    ) {
        self.volatileFields = volatileFields
        self.numericEpsilon = numericEpsilon
        self.timingBudgets = timingBudgets
        self.unorderedGroups = unorderedGroups
        self.ignoredKinds = ignoredKinds
        self.ignoredNotificationNames = ignoredNotificationNames
        self.structuralComparison = structuralComparison
        self.domainMigration = domainMigration
        self.concurrency = concurrency
        self.spawnEdges = spawnEdges
        self.mutationOrder = mutationOrder
        self.observedStateLabels = observedStateLabels
    }

    /// The default: exact match on everything (nondeterminism already removed by canonicalization of
    /// timestamps/addresses/threads, but volatile *values* like UUIDs are NOT tolerated here).
    public static let strict = Tolerance()
}

extension VolatileField: Codable {
    enum CodingKeys: String, CodingKey { case key, label, path }

    /// A bare string is an unscoped key (unambiguous in JSON, kept for hand-written specs); an
    /// object carries exactly one of `key` / `path` (dotted) plus optional `label`.
    public init(from decoder: Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            self.init(position: .key(bare), label: nil)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        let key = try container.decodeIfPresent(String.self, forKey: .key)
        let path = try container.decodeIfPresent(String.self, forKey: .path)
        switch (key, path) {
        case (let key?, nil):
            self.init(position: .key(key), label: label)
        case (nil, let path?):
            guard let components = VolatileField.parsePath(path) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "path \"\(path)\" must be dot-separated non-empty components"
                )
            }
            self.init(position: .path(components), label: label)
        case (.some, .some):
            throw DecodingError.dataCorruptedError(
                forKey: .key,
                in: container,
                debugDescription: "a volatile field takes key or path, not both"
            )
        case (nil, nil):
            throw DecodingError.dataCorruptedError(
                forKey: .key,
                in: container,
                debugDescription: "a volatile field needs a key or a path"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case let .key(key) = position, label == nil {
            var single = encoder.singleValueContainer()
            try single.encode(key)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch position {
        case let .key(key): try container.encode(key, forKey: .key)
        case let .path(path): try container.encode(path.joined(separator: "."), forKey: .path)
        }
        try container.encodeIfPresent(label, forKey: .label)
    }
}

extension Tolerance: Codable {
    enum CodingKeys: String, CodingKey {
        case volatileFields, numericEpsilon, timingBudgets, unorderedGroups, ignoredKinds
        case ignoredNotificationNames, structuralComparison, domainMigration, concurrency, spawnEdges
        case mutationOrder, observedStateLabels
    }

    /// Every field is optional in JSON so a partial spec is ergonomic.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volatileFields = try container.decodeIfPresent([VolatileField].self, forKey: .volatileFields) ?? []
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
        mutationOrder = try container
            .decodeIfPresent(MutationOrderPolicy.self, forKey: .mutationOrder) ?? .advisory
        observedStateLabels = try container
            .decodeIfPresent([String].self, forKey: .observedStateLabels)
    }
}

public extension Tolerance {
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Tolerance.self, from: Data(contentsOf: url))
    }

    func isVolatile(key: String, label: String, path: [String]) -> Bool {
        volatileFields.contains { $0.matches(key: key, label: label, path: path) }
    }

    func isUnordered(label: String) -> Bool {
        unorderedGroups.contains { $0.contains(label) }
    }

    func timingBudget(for label: String) -> Int64? {
        timingBudgets[label]
    }
}
