import Foundation

/// The declared "expected behavioral change" for a feature or enhancement — the symmetric complement
/// to `Comparison`.
///
/// A comparison says which deltas *aren't behavior* (jitter, timing within budget, order) and sets
/// them aside before diffing. Intent says which deltas were *meant to happen* (the feature) and are surfaced but
/// reclassified `.intended`, so they don't gate the verdict. Whatever remains is `.collateral`: an
/// undeclared change the author didn't intend — the thing an extension-mode gate fails on.
///
/// **Parity mode (migrations) is simply `Intent.none`.** Extension mode (features) is a populated
/// spec. Same engine; the only difference is how much change was declared up front.
///
/// A declaration is a *standing excuse*, so each one is as narrow as its author can make it: a
/// modifier (`ValueRelation`, `InputCondition`, `OpScope`, `Position`) narrows the match, and
/// whatever the narrowed declaration rejects stays collateral.
public struct Intent: Sendable, Equatable {
    /// One declared movement of work between isolation domains, named the way an author names
    /// domains (`DomainName`): a queue by label whatever its discipline, an actor by type whatever
    /// its instance. Scoped to the event labels it names — an empty list means every label, the
    /// wholesale form. The DSL spellings are `Moves(_:from:to:)` and `Moves(everythingFrom:to:)`,
    /// narrowed to one op with `.only(in:)`.
    public struct DomainMove: Sendable, Equatable, Codable {
        public let labels: [String]
        public let origin: DomainName
        public let destination: DomainName
        /// `.only(in:)` — the declared op the move belongs to.
        public var scope: OpScope?

        public init(
            labels: [String] = [],
            from origin: DomainName,
            to destination: DomainName,
            scope: OpScope? = nil
        ) {
            self.labels = labels
            self.origin = origin
            self.destination = destination
            self.scope = scope
        }

        func matches(label: String, from actualFrom: String?, to actualTo: String?) -> Bool {
            (labels.isEmpty || labels.contains(label))
                && origin.matches(actualFrom) && destination.matches(actualTo)
        }

        var dslText: String {
            let head = labels.isEmpty
                ? "everythingFrom: "
                : labels.map(quoted).joined(separator: ", ") + ", from: "
            return "Moves(\(head)\(origin.dslText), to: \(destination.dslText))" + (scope?.dslText ?? "")
        }
    }

    /// One declared event addition or removal (`Emits` / `Omits`), narrowed by its modifiers.
    ///
    /// A bare label is the unconditioned declaration, so a string literal spells one:
    /// `expectedNewEvents: ["LoyaltyPointsEarned"]`.
    public struct EventChange: Sendable, Equatable, ExpressibleByStringLiteral {
        public var label: String
        /// `.when(_:is:)` conditions, every one of which must hold in the probe.
        public var conditions: [InputCondition]
        /// `.only(in:)` / `.once(per:)` — the declared op the event belongs to.
        public var scope: OpScope?
        /// `.after(_:)` / `.before(_:)` — where the event sits relative to another.
        public var position: Position?

        public init(
            _ label: String,
            when conditions: [InputCondition] = [],
            scope: OpScope? = nil,
            position: Position? = nil
        ) {
            self.label = label
            self.conditions = conditions
            self.scope = scope
            self.position = position
        }

        public init(stringLiteral label: String) {
            self.init(label)
        }

        /// The unmodified form, which JSON spells as a plain string.
        var isBare: Bool {
            conditions.isEmpty && scope == nil && position == nil
        }

        var modifiersText: String {
            conditions.dslText + (scope?.dslText ?? "") + (position?.dslText ?? "")
        }

        /// Every modifier holds for `divergence`, whose event sits at `seq` on the side `events`
        /// came from.
        func modifiersHold(
            for divergence: Divergence,
            at seq: Int?,
            in events: [TraceEvent],
            evidence: ProbeEvidence
        ) -> Bool {
            conditions.allHold(in: evidence.inputs)
                && scope.map { $0.holds(for: divergence, among: evidence.siblings(of: divergence)) } ?? true
                && position.map { $0.holds(at: seq, in: events) } ?? true
        }
    }

    /// One declared reorder (`Reorders`): the event label, and optionally the direction it moved
    /// in — `Reorders("Archive.archive", before: "CartDidChange")`.
    ///
    /// A bare label is the undirected form, so a string literal spells one.
    public struct Reorder: Sendable, Equatable, ExpressibleByStringLiteral {
        public var label: String
        /// The declared direction: the event now sits `before` (or `after`) the anchor in the
        /// candidate, having sat on the other side of it in the baseline.
        public var position: Position?

        public init(_ label: String, position: Position? = nil) {
            self.label = label
            self.position = position
        }

        public init(stringLiteral label: String) {
            self.init(label)
        }

        var dslText: String {
            position.map { "Reorders(\(quoted(label)), \($0.argumentText))" } ?? "Reorders(\(quoted(label)))"
        }
    }

    /// One declared payload change (`Changes`): a label, the field that may differ (`nil` = any
    /// field of that event), and the modifiers that say how.
    ///
    /// Declaring one field does NOT excuse a change to another field of the same event, and a
    /// relation or condition excuses only the values it names — intent must be specific.
    public struct ValueChange: Sendable, Equatable {
        public var label: String
        public var field: String?
        public var relation: ValueRelation?
        public var conditions: [InputCondition]
        /// `.only(in:)` — the declared op the change belongs to.
        public var scope: OpScope?

        public init(
            _ label: String,
            field: String? = nil,
            relation: ValueRelation? = nil,
            when conditions: [InputCondition] = [],
            scope: OpScope? = nil
        ) {
            self.label = label
            self.field = field
            self.relation = relation
            self.conditions = conditions
            self.scope = scope
        }

        /// The bare, wholesale form (`Changes("Receipt")`) — no field, no modifier — which subsumes
        /// every narrower declaration on the same label.
        var isWholesale: Bool {
            field == nil && relation == nil && conditions.isEmpty && scope == nil
        }
    }

    /// Events the change is allowed to ADD (present in candidate, absent in baseline).
    public var expectedNewEvents: [EventChange]

    /// Events the change is allowed to REMOVE (present in baseline, absent in candidate).
    public var expectedRemovedEvents: [EventChange]

    /// Payload changes the change is allowed to make, one declaration per (label, field, modifiers).
    public var expectedValueChanges: [ValueChange]

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

    /// Events (by label) the change deliberately reorders — `reordered`. A port that emits its effects
    /// in a different order declares the labels it moves, and only those. The DSL spelling is
    /// `Reorders(_:)`, directed with `Reorders(_:before:)` / `Reorders(_:after:)`.
    public var expectedReorders: [Reorder]

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
        expectedNewEvents: [EventChange] = [],
        expectedRemovedEvents: [EventChange] = [],
        expectedValueChanges: [ValueChange] = [],
        expectedOrderingRelaxations: [DomainName] = [],
        expectedOrderingLosses: [String] = [],
        expectedOrderingAdditions: [String] = [],
        expectedReorders: [Reorder] = [],
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

    /// Returns whether this spec declares `divergence` as an intended change. A declared divergence
    /// is reclassified as intended, so it discloses on the report instead of gating the verdict.
    /// - Parameters:
    ///   - divergence: One divergence of the comparison being classified.
    ///   - evidence: What the probe left behind (seam inputs, both aligned event streams, the
    ///     sibling divergences) for value, position, and cardinality modifiers to test; `.none`
    ///     when the caller has no probe context, which lets only unmodified declarations match.
    /// - Returns: `true` when some declaration's head matches and every modifier on it holds.
    public func declares(_ divergence: Divergence, evidence: ProbeEvidence = .none) -> Bool {
        declarations.contains { $0.matches(divergence, evidence) }
    }

    /// Returns whether this spec declares `divergence` as an intended change, judging by the probe's
    /// seam inputs alone. Callers that never see the aligned event streams need not build a `ProbeEvidence`.
    /// - Parameters:
    ///   - divergence: One divergence of the comparison being classified.
    ///   - inputs: The seam inputs the probe ran with; `nil` means none were recorded, so
    ///     `.when(_:is:)` conditions cannot hold.
    /// - Returns: `true` when some declaration matches under that evidence alone.
    public func declares(_ divergence: Divergence, inputs: ProbeInputs?) -> Bool {
        declares(divergence, evidence: ProbeEvidence(inputs: inputs))
    }

    /// A declared field matches the leaf that differed, or any leaf beneath it (`info` covers
    /// `info.pointsEarned` and `info[0]`).
    static func fieldMatches(_ field: String, _ path: String?) -> Bool {
        guard let path else {
            return false
        }
        return path == field || path.hasPrefix("\(field).") || path.hasPrefix("\(field)[")
    }
}

extension Intent.ValueChange {
    /// The declaration's one spelling: head, then relation, then conditions, then scope.
    var dslText: String {
        let head = field.map { "Changes(\(quoted(label)), field: \(quoted($0)))" } ?? "Changes(\(quoted(label)))"
        return head + (relation?.dslText ?? "") + conditions.dslText + (scope?.dslText ?? "")
    }
}

public extension Intent {
    /// Every atomic declaration's DSL spelling, in `declarations` order — the list tooling prints
    /// when it names what an intent claims.
    var declarationTexts: [String] {
        declarations.map(\.text)
    }

    /// Returns the union of this spec and `other`: every declaration either side makes, once.
    ///
    /// Sound only where the combined excuses were each individually endorsed — the record-on-merge
    /// sweep replaying one plan across several merged PRs' declarations. A union must never judge a
    /// single PR: it would absorb divergences that PR never declared.
    ///
    /// Modifiers survive the union: two PRs narrowing the same label keep both narrow forms rather
    /// than widening each other. Only a wholesale `Changes(label)` subsumes that label's narrower
    /// forms, because it already absorbs everything they do.
    func merging(_ other: Intent) -> Intent {
        let valueChanges = uniqued(expectedValueChanges + other.expectedValueChanges)
        let wholesale = Set(valueChanges.filter(\.isWholesale).map(\.label))
        return Intent(
            expectedNewEvents: uniqued(expectedNewEvents + other.expectedNewEvents),
            expectedRemovedEvents: uniqued(expectedRemovedEvents + other.expectedRemovedEvents),
            expectedValueChanges: valueChanges.filter { $0.isWholesale || !wholesale.contains($0.label) },
            expectedOrderingRelaxations: uniqued(
                expectedOrderingRelaxations + other.expectedOrderingRelaxations
            ),
            expectedOrderingLosses: uniqued(expectedOrderingLosses + other.expectedOrderingLosses),
            expectedOrderingAdditions: uniqued(
                expectedOrderingAdditions + other.expectedOrderingAdditions
            ),
            expectedReorders: uniqued(expectedReorders + other.expectedReorders),
            expectedDomainMigrations: uniqued(expectedDomainMigrations + other.expectedDomainMigrations),
            acceptedBlindSpots: uniqued(acceptedBlindSpots + other.acceptedBlindSpots)
        )
    }
}

/// First occurrence wins, order preserved — a merged intent renders declarations in the order the
/// PRs merged, which is the order a reader can retrace.
private func uniqued<T: Equatable>(_ values: [T]) -> [T] {
    values.reduce(into: []) { result, value in
        if !result.contains(value) {
            result.append(value)
        }
    }
}

public extension TraceDiff {
    /// Extension mode: reclassify divergences the intent spec declared as `.intended`, then re-derive
    /// the verdict from the residual (gating, collateral) divergences. `Intent.none` is a no-op
    /// (parity mode) — every divergence stays collateral and the verdict is unchanged.
    ///
    /// `evidence` is what the probe left behind — its seam reads for `.when(_:is:)`, both aligned
    /// traces for `.after` / `.before`; without it no such declaration can match. The comparison's
    /// own divergences are supplied here, for `.once(per:)` to count against.
    ///
    /// A collateral divergence some declaration was about but rejected keeps that declaration's
    /// spelling in `rejectedBy`.
    ///
    /// Also records `unobservedIntent`: the declarations that matched nothing *in this comparison*.
    /// For a single diff that is the finished fact; a sweep that compares many probes intersects the
    /// per-probe sets (a declaration is observed if any probe matched it) and overwrites the
    /// reported diff's copy — see `Spec.verify`.
    func classified(against intent: Intent, evidence: ProbeEvidence = .none) -> TraceDiff {
        var result = self
        var evidence = evidence
        evidence.divergences = divergences
        var observed = Set<String>()
        let declarations = intent.declarations
        for index in result.divergences.indices {
            let divergence = result.divergences[index]
            var matched = false
            for declaration in declarations where declaration.matches(divergence, evidence) {
                observed.insert(declaration.text)
                matched = true
            }
            if matched {
                result.divergences[index].classification = .intended
            } else {
                // A declaration about this divergence whose modifier said no: the author's own
                // tripwire, named so the report can say which line fired rather than offer a wider one.
                result.divergences[index].rejectedBy = declarations
                    .filter { $0.headMatches(divergence) }
                    .map(\.text)
            }
        }
        result.unobservedIntent = declarations.map(\.text).filter { !observed.contains($0) }
        result.verdict = result.divergences.contains(where: \.isGating) ? .diverged : .equivalent
        return result
    }

    /// `classified(against:evidence:)` with only the probe's seam inputs in hand.
    func classified(against intent: Intent, inputs: ProbeInputs?) -> TraceDiff {
        classified(against: intent, evidence: ProbeEvidence(inputs: inputs))
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
