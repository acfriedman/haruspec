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
    case strict    // structural divergences fail the verdict
    case advisory  // structural divergences are reported but do not fail the verdict
    case ignored   // structural events are dropped; only semantic events are compared
}

public struct ToleranceSpec: Sendable, Equatable {
    /// Payload keys (matched by name at any depth) whose values are non-deterministic and must be
    /// ignored — e.g. `"orderID"`, `"issuedAt"`. Redacted to a placeholder before comparison.
    public var volatileFields: [String]

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

    /// Notification names to drop before diffing. Since scenarios capture *all* notifications by
    /// default, this is the opt-out for a specific noisy channel: it removes matching `.notification`
    /// events from both sides at diff time, leaving the raw trace faithful. Mirrors `ignoredKinds` but
    /// scoped by name rather than kind.
    public var ignoredNotificationNames: [String]

    /// How the structural (auto-captured) tier participates in the verdict. Defaults to `.strict`.
    public var structuralComparison: StructuralComparison

    public init(volatileFields: [String] = [],
                numericEpsilon: Double = 0,
                timingBudgets: [String: Int64] = [:],
                unorderedGroups: [[String]] = [],
                ignoredKinds: [EventKind] = [],
                ignoredNotificationNames: [String] = [],
                structuralComparison: StructuralComparison = .strict) {
        self.volatileFields = volatileFields
        self.numericEpsilon = numericEpsilon
        self.timingBudgets = timingBudgets
        self.unorderedGroups = unorderedGroups
        self.ignoredKinds = ignoredKinds
        self.ignoredNotificationNames = ignoredNotificationNames
        self.structuralComparison = structuralComparison
    }

    /// The default: exact match on everything (nondeterminism already removed by canonicalization of
    /// timestamps/addresses/threads, but volatile *values* like UUIDs are NOT tolerated here).
    public static let strict = ToleranceSpec()
}

extension ToleranceSpec: Codable {
    enum CodingKeys: String, CodingKey {
        case volatileFields, numericEpsilon, timingBudgets, unorderedGroups, ignoredKinds
        case ignoredNotificationNames, structuralComparison
    }

    // Every field is optional in JSON so a partial spec is ergonomic.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volatileFields = try c.decodeIfPresent([String].self, forKey: .volatileFields) ?? []
        numericEpsilon = try c.decodeIfPresent(Double.self, forKey: .numericEpsilon) ?? 0
        timingBudgets = try c.decodeIfPresent([String: Int64].self, forKey: .timingBudgets) ?? [:]
        unorderedGroups = try c.decodeIfPresent([[String]].self, forKey: .unorderedGroups) ?? []
        ignoredKinds = try c.decodeIfPresent([EventKind].self, forKey: .ignoredKinds) ?? []
        ignoredNotificationNames = try c.decodeIfPresent([String].self, forKey: .ignoredNotificationNames) ?? []
        structuralComparison = try c.decodeIfPresent(StructuralComparison.self, forKey: .structuralComparison) ?? .strict
    }
}

public extension ToleranceSpec {
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(ToleranceSpec.self, from: Data(contentsOf: url))
    }

    func isVolatile(key: String) -> Bool { volatileFields.contains(key) }
    func isUnordered(label: String) -> Bool { unorderedGroups.contains { $0.contains(label) } }
    func timingBudget(for label: String) -> Int64? { timingBudgets[label] }
}
