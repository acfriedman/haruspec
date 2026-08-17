import Foundation

/// The declared "expected behavioral change" for a feature or enhancement — the symmetric complement
/// to `Tolerance`.
///
/// Tolerances say which deltas *don't matter* (volatile fields, jitter, order) and are filtered out
/// before diffing. Intent says which deltas were *meant to happen* (the feature) and are surfaced but
/// reclassified `.intended`, so they don't gate the verdict. Whatever remains is `.collateral`: an
/// undeclared change the author didn't intend — the thing an extension-mode gate fails on.
///
/// **Parity mode (migrations) is simply `Intent.none`.** Extension mode (features) is a populated
/// spec. Same engine; the only difference is how much change was declared up front.
public struct Intent: Sendable, Equatable {
    /// One declared movement of work between isolation domains, named the way an author names
    /// domains (`DomainName`): a queue by label whatever its discipline, an actor by type whatever
    /// its instance. Scoped to the event labels it names — an empty list means every label, the
    /// wholesale form. The DSL spellings are `Moves(_:from:to:)` and `Moves(everythingFrom:to:)`.
    public struct DomainMove: Sendable, Equatable, Codable {
        public let labels: [String]
        public let origin: DomainName
        public let destination: DomainName

        public init(labels: [String] = [], from origin: DomainName, to destination: DomainName) {
            self.labels = labels
            self.origin = origin
            self.destination = destination
        }

        func matches(label: String, from actualFrom: String?, to actualTo: String?) -> Bool {
            (labels.isEmpty || labels.contains(label))
                && origin.matches(actualFrom) && destination.matches(actualTo)
        }
    }

    /// Event labels the change is allowed to ADD (present in candidate, absent in baseline).
    public var expectedNewEvents: [String]

    /// Event labels the change is allowed to REMOVE (present in baseline, absent in candidate).
    public var expectedRemovedEvents: [String]

    /// Value changes the change is allowed to make: event label → the payload field paths that may
    /// differ. An empty field list means "any value change on this label is intended." Declaring one
    /// field does NOT excuse a change to another field of the same event — intent must be specific.
    public var expectedValueChanges: [String: [String]]

    /// Ordered domains whose ordering guarantee the change deliberately drops (`orderingRelaxed`).
    /// Replacing a serial queue with a task group is the canonical case: the relaxation is the point
    /// of the PR, so it is declarable — and gates until declared. The DSL spelling is
    /// `Relaxes(orderingOf:)`.
    public var expectedOrderingRelaxations: [DomainName]

    /// Events (by label) whose happens-before constraint the change deliberately drops — the
    /// `orderingLost` counterpart of a relaxation. A gate with no declarable exit would veto the
    /// work instead of checking it.
    public var expectedOrderingLosses: [String]

    /// Events (by label) the change deliberately *newly synchronizes* — `orderingAdded`. The awaited
    /// port of fire-and-forget work is the canonical case: everything after the call now waits.
    public var expectedOrderingAdditions: [String]

    /// Events (by label) the change deliberately reorders — `reordered`. Property writes under
    /// `MutationOrderPolicy.gating` are the motivating case: a port that computes its state in a
    /// different order declares the labels it moves, and only those. The DSL spelling is
    /// `Reorders(_:)`.
    public var expectedReorders: [String]

    /// Movements of work between isolation domains the change intends — a port's one-line summary
    /// (`DomainMove(from: "queue(serial):com.emporium.cart", to: "actor:SwiftCartActor")`) rather
    /// than one declaration per migrated event. Declaring one pair does NOT excuse another.
    public var expectedDomainMigrations: [DomainMove]

    /// Effect channels the author accepts the capture cannot see (`"Timer / RunLoop"`), by the name
    /// the capture-completeness audit gives them. The only exit from a `bypassedChannel` gap, and a
    /// deliberately weak one: it does not hide the channel, it *names* it on the verdict as a
    /// declared blind spot. The DSL spelling is `Accepts(uncaptured:)`.
    ///
    /// Unlike the divergence declarations above, this excuses something the diff never saw — so the
    /// audit also reports a declaration that matched nothing. An accepted blind spot that no longer
    /// exists is the allowlist failure again: an entry matching nothing looks exactly like one that
    /// matches.
    public var acceptedBlindSpots: [String]

    public init(
        expectedNewEvents: [String] = [],
        expectedRemovedEvents: [String] = [],
        expectedValueChanges: [String: [String]] = [:],
        expectedOrderingRelaxations: [DomainName] = [],
        expectedOrderingLosses: [String] = [],
        expectedOrderingAdditions: [String] = [],
        expectedReorders: [String] = [],
        expectedDomainMigrations: [DomainMove] = [],
        acceptedBlindSpots: [String] = []
    ) {
        self.expectedNewEvents = expectedNewEvents
        self.expectedRemovedEvents = expectedRemovedEvents
        self.expectedValueChanges = expectedValueChanges
        self.expectedOrderingRelaxations = expectedOrderingRelaxations
        self.expectedOrderingLosses = expectedOrderingLosses
        self.expectedOrderingAdditions = expectedOrderingAdditions
        self.expectedReorders = expectedReorders
        self.expectedDomainMigrations = expectedDomainMigrations
        self.acceptedBlindSpots = acceptedBlindSpots
    }

    /// The empty spec: nothing was declared, so every divergence stays collateral. This is parity mode.
    public static let none = Intent()

    /// Does this spec declare `divergence` as an intended change?
    public func declares(_ divergence: Divergence) -> Bool {
        switch divergence.kind {
        case .unexpectedEvent:
            return expectedNewEvents.contains(divergence.label)
        case .missingEvent:
            return expectedRemovedEvents.contains(divergence.label)
        case .valueMismatch:
            guard let fields = expectedValueChanges[divergence.label] else { return false }
            return fields.isEmpty || fields.contains { fieldMatches($0, divergence.detail) }
        case .orderingRelaxed:
            return expectedOrderingRelaxations.contains { $0.matches(divergence.fromDomain) }
        case .orderingLost:
            return expectedOrderingLosses.contains(divergence.label)
        case .orderingAdded:
            return expectedOrderingAdditions.contains(divergence.label)
        case .domainMigration:
            return expectedDomainMigrations.contains {
                $0.matches(label: divergence.label, from: divergence.fromDomain, to: divergence.toDomain)
            }
        case .reordered:
            return expectedReorders.contains(divergence.label)
        case .timingRegression:
            return false // not yet expressible as declared intent — always collateral for now
        }
    }

    /// A value-mismatch `detail` reads `"<path>: baseline=… candidate=…"`; match on that leading path.
    private func fieldMatches(_ field: String, _ detail: String) -> Bool {
        let path = detail.range(of: ": ").map { String(detail[..<$0.lowerBound]) } ?? detail
        return path == field || path.hasPrefix("\(field).") || path.hasPrefix("\(field)[")
    }
}

public extension TraceDiff {
    /// Extension mode: reclassify divergences the intent spec declared as `.intended`, then re-derive
    /// the verdict from the residual (gating, collateral) divergences. `Intent.none` is a no-op
    /// (parity mode) — every divergence stays collateral and the verdict is unchanged.
    func classified(against intent: Intent) -> TraceDiff {
        var result = self
        for index in result.divergences.indices where intent.declares(result.divergences[index]) {
            result.divergences[index].classification = .intended
        }
        result.verdict = result.divergences.contains(where: \.isGating) ? .diverged : .equivalent
        return result
    }

    /// Divergences the intent spec declared — expected feature behavior.
    var intendedCount: Int {
        divergences.filter { $0.classification == .intended }.count
    }

    /// Undeclared divergences that gate the verdict — suspected regressions.
    var collateralCount: Int {
        divergences.filter(\.isGating).count
    }
}

extension Intent: Codable {
    enum CodingKeys: String, CodingKey {
        case expectedNewEvents, expectedRemovedEvents, expectedValueChanges
        case expectedOrderingRelaxations, expectedOrderingLosses, expectedOrderingAdditions
        case expectedReorders, expectedDomainMigrations, acceptedBlindSpots
    }

    /// Every field is optional in JSON so a partial spec is ergonomic.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectedNewEvents = try container.decodeIfPresent([String].self, forKey: .expectedNewEvents) ?? []
        expectedRemovedEvents = try container.decodeIfPresent([String].self, forKey: .expectedRemovedEvents) ?? []
        expectedValueChanges = try container
            .decodeIfPresent([String: [String]].self, forKey: .expectedValueChanges) ?? [:]
        expectedOrderingRelaxations = try container
            .decodeIfPresent([DomainName].self, forKey: .expectedOrderingRelaxations) ?? []
        expectedOrderingLosses = try container
            .decodeIfPresent([String].self, forKey: .expectedOrderingLosses) ?? []
        expectedOrderingAdditions = try container
            .decodeIfPresent([String].self, forKey: .expectedOrderingAdditions) ?? []
        expectedReorders = try container
            .decodeIfPresent([String].self, forKey: .expectedReorders) ?? []
        expectedDomainMigrations = try container
            .decodeIfPresent([DomainMove].self, forKey: .expectedDomainMigrations) ?? []
        acceptedBlindSpots = try container
            .decodeIfPresent([String].self, forKey: .acceptedBlindSpots) ?? []
    }
}

public extension Intent {
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: url))
    }
}
