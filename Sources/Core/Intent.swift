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
    /// Event labels the change is allowed to ADD (present in candidate, absent in baseline).
    public var expectedNewEvents: [String]

    /// Event labels the change is allowed to REMOVE (present in baseline, absent in candidate).
    public var expectedRemovedEvents: [String]

    /// Value changes the change is allowed to make: event label → the payload field paths that may
    /// differ. An empty field list means "any value change on this label is intended." Declaring one
    /// field does NOT excuse a change to another field of the same event — intent must be specific.
    public var expectedValueChanges: [String: [String]]

    /// Ordered domains whose ordering guarantee the change deliberately drops, named as an author
    /// declares them — a queue by its bare label (`"com.emporium.cart"`), `main` or an actor by its
    /// description. Replacing a serial queue with a task group is the canonical case: the relaxation
    /// is the point of the PR, so it is declarable — and `orderingRelaxed` gates until it is.
    public var expectedOrderingRelaxations: [String]

    /// Events (by label) whose happens-before constraint the change deliberately drops — the
    /// `orderingLost` counterpart of a relaxation. Only consulted when `Tolerance.spawnEdges` is
    /// `.gating`; a gate with no declarable exit would veto the work instead of checking it.
    public var expectedOrderingLosses: [String]

    public init(
        expectedNewEvents: [String] = [],
        expectedRemovedEvents: [String] = [],
        expectedValueChanges: [String: [String]] = [:],
        expectedOrderingRelaxations: [String] = [],
        expectedOrderingLosses: [String] = []
    ) {
        self.expectedNewEvents = expectedNewEvents
        self.expectedRemovedEvents = expectedRemovedEvents
        self.expectedValueChanges = expectedValueChanges
        self.expectedOrderingRelaxations = expectedOrderingRelaxations
        self.expectedOrderingLosses = expectedOrderingLosses
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
            return expectedOrderingRelaxations.contains(divergence.label)
        case .orderingLost:
            return expectedOrderingLosses.contains(divergence.label)
        // A domain move is not declarable yet: `Intent` has no vocabulary for "this work moved to an
        // actor on purpose". Until it does, the policy on `Tolerance` is the only dial.
        // `orderingAdded` is always advisory, so declaring it would change nothing.
        case .reordered, .timingRegression, .domainMigration, .orderingAdded:
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
        case expectedOrderingRelaxations, expectedOrderingLosses
    }

    /// Every field is optional in JSON so a partial spec is ergonomic.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectedNewEvents = try container.decodeIfPresent([String].self, forKey: .expectedNewEvents) ?? []
        expectedRemovedEvents = try container.decodeIfPresent([String].self, forKey: .expectedRemovedEvents) ?? []
        expectedValueChanges = try container
            .decodeIfPresent([String: [String]].self, forKey: .expectedValueChanges) ?? [:]
        expectedOrderingRelaxations = try container
            .decodeIfPresent([String].self, forKey: .expectedOrderingRelaxations) ?? []
        expectedOrderingLosses = try container
            .decodeIfPresent([String].self, forKey: .expectedOrderingLosses) ?? []
    }
}

public extension Intent {
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: url))
    }
}
