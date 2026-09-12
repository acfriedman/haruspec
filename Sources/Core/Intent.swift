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
///
/// A declaration is a *standing excuse*, so each one is as narrow as its author can make it: a
/// modifier (`ValueRelation`, `InputCondition`) narrows the match, and whatever the narrowed
/// declaration rejects stays collateral.
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

    /// One declared event addition or removal (`Emits` / `Omits`), narrowed by its conditions.
    ///
    /// A bare label is the unconditioned declaration, so a string literal spells one:
    /// `expectedNewEvents: ["LoyaltyPointsEarned"]`.
    public struct EventChange: Sendable, Equatable, ExpressibleByStringLiteral {
        public var label: String
        /// `.when(_:is:)` conditions, every one of which must hold in the probe.
        public var conditions: [InputCondition]

        public init(_ label: String, when conditions: [InputCondition] = []) {
            self.label = label
            self.conditions = conditions
        }

        public init(stringLiteral label: String) {
            self.init(label)
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

        public init(
            _ label: String,
            field: String? = nil,
            relation: ValueRelation? = nil,
            when conditions: [InputCondition] = []
        ) {
            self.label = label
            self.field = field
            self.relation = relation
            self.conditions = conditions
        }

        /// The bare, wholesale form (`Changes("Receipt")`) — no field, no modifier — which subsumes
        /// every narrower declaration on the same label.
        var isWholesale: Bool {
            field == nil && relation == nil && conditions.isEmpty
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
        expectedNewEvents: [EventChange] = [],
        expectedRemovedEvents: [EventChange] = [],
        expectedValueChanges: [ValueChange] = [],
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

    /// Does this spec declare `divergence` as an intended change, in a probe that read `inputs`?
    public func declares(_ divergence: Divergence, inputs: ProbeInputs? = nil) -> Bool {
        declarations.contains { $0.matches(divergence, inputs) }
    }

    /// A declared field matches the leaf that differed, or any leaf beneath it (`info` covers
    /// `info.pointsEarned` and `info[0]`).
    private static func fieldMatches(_ field: String, _ path: String?) -> Bool {
        guard let path else {
            return false
        }
        return path == field || path.hasPrefix("\(field).") || path.hasPrefix("\(field)[")
    }
}

/// One atomic declaration inside an `Intent` — the unit "declared but not observed" is measured in.
///
/// `text` is the declaration's DSL spelling (`Changes("Search.query").increases()`), so a warning
/// about a dead declaration names exactly the line to delete.
struct IntentDeclaration: Sendable {
    let text: String
    let matches: @Sendable (Divergence, ProbeInputs?) -> Bool
}

extension Intent {
    /// The intent exploded into its atomic declarations, each pairing a matcher with its DSL spelling.
    ///
    /// `declares(_:inputs:)` is a fold over this list, and the unobserved-intent check is its
    /// complement: a declaration no divergence matched describes a change nobody saw.
    ///
    /// `acceptedBlindSpots` is deliberately absent: it excuses a *channel* the diff could never
    /// observe, and the capture-completeness audit already reports an acceptance that matched
    /// nothing (`AuditOutcome`).
    ///
    /// Order is deterministic (kind-grouped, value changes label-sorted) so the warning renders
    /// stably across runs.
    var declarations: [IntentDeclaration] {
        var atoms: [IntentDeclaration] = []
        for event in expectedNewEvents {
            atoms.append(IntentDeclaration(text: "Emits(\(quoted(event.label)))\(event.conditions.dslText)") {
                $0.kind == .unexpectedEvent && $0.label == event.label && event.conditions.allHold(in: $1)
            })
        }
        for event in expectedRemovedEvents {
            atoms.append(IntentDeclaration(text: "Omits(\(quoted(event.label)))\(event.conditions.dslText)") {
                $0.kind == .missingEvent && $0.label == event.label && event.conditions.allHold(in: $1)
            })
        }
        // Per-field atoms: declaring one field never excuses — and is never excused by — another.
        let valueChanges = expectedValueChanges.sorted {
            ($0.label, $0.field ?? "") < ($1.label, $1.field ?? "")
        }
        for change in valueChanges {
            atoms.append(IntentDeclaration(text: change.dslText) { divergence, inputs in
                divergence.kind == .valueMismatch
                    && divergence.label == change.label
                    && change.field.map { Self.fieldMatches($0, divergence.field) } ?? true
                    && change.relation.map {
                        $0.holds(baseline: divergence.baselineValue, candidate: divergence.candidateValue)
                    } ?? true
                    && change.conditions.allHold(in: inputs)
            })
        }
        for domain in expectedOrderingRelaxations {
            atoms.append(IntentDeclaration(text: "Relaxes(orderingOf: \(domain.dslText))") { divergence, _ in
                divergence.kind == .orderingRelaxed && domain.matches(divergence.fromDomain)
            })
        }
        for label in expectedOrderingLosses {
            atoms.append(IntentDeclaration(text: "Drops(synchronizationOf: \(quoted(label)))") { divergence, _ in
                divergence.kind == .orderingLost && divergence.label == label
            })
        }
        for label in expectedOrderingAdditions {
            atoms.append(IntentDeclaration(text: "Awaits(\(quoted(label)))") { divergence, _ in
                divergence.kind == .orderingAdded && divergence.label == label
            })
        }
        for label in expectedReorders {
            atoms.append(IntentDeclaration(text: "Reorders(\(quoted(label)))") { divergence, _ in
                divergence.kind == .reordered && divergence.label == label
            })
        }
        for move in expectedDomainMigrations {
            let scope = move.labels.isEmpty
                ? "everythingFrom: "
                : move.labels.map(quoted).joined(separator: ", ") + ", from: "
            atoms.append(IntentDeclaration(
                text: "Moves(\(scope)\(move.origin.dslText), to: \(move.destination.dslText))"
            ) { divergence, _ in
                divergence.kind == .domainMigration
                    && move.matches(label: divergence.label, from: divergence.fromDomain, to: divergence.toDomain)
            })
        }
        return atoms
    }
}

extension Intent.ValueChange {
    /// The declaration's one spelling: head, then relation, then conditions.
    var dslText: String {
        let head = field.map { "Changes(\(quoted(label)), field: \(quoted($0)))" } ?? "Changes(\(quoted(label)))"
        return head + (relation?.dslText ?? "") + conditions.dslText
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

public extension Divergence {
    /// The declaration that would mark this divergence intended — the exact line the teaching loop
    /// offers on a red verdict, and a line `IntentGrammar` parses back.
    ///
    /// The narrowest line the divergence proves: a value mismatch with a scalar new value is
    /// offered as `.to(<value>)`, which pins exactly what this probe observed. An author whose
    /// change is a direction or a range rather than one value widens it (`.increases()`,
    /// `.within(…)`, or the bare field) — the loop pushes toward precision by default.
    ///
    /// `nil` for a divergence that is not expressible as intent (timing regressions) or whose
    /// domains did not resolve.
    var suggestedDeclaration: String? {
        switch kind {
        case .unexpectedEvent:
            return "Emits(\(quoted(label)))"
        case .missingEvent:
            return "Omits(\(quoted(label)))"
        case .valueMismatch:
            let relation = candidateValue.flatMap { $0.isScalar ? ValueRelation.to($0) : nil }
            return Intent.ValueChange(label, field: field, relation: relation).dslText
        case .orderingRelaxed:
            return fromDomain.flatMap(DomainName.init(recorded:))
                .map { "Relaxes(orderingOf: \($0.dslText))" }
        case .orderingLost:
            return "Drops(synchronizationOf: \(quoted(label)))"
        case .orderingAdded:
            return "Awaits(\(quoted(label)))"
        case .reordered:
            return "Reorders(\(quoted(label)))"
        case .domainMigration:
            guard let origin = fromDomain.flatMap(DomainName.init(recorded:)),
                  let destination = toDomain.flatMap(DomainName.init(recorded:)) else {
                return nil
            }
            return "Moves(\(quoted(label)), from: \(origin.dslText), to: \(destination.dslText))"
        case .timingRegression:
            return nil // not expressible as declared intent — always collateral
        }
    }
}

private func quoted(_ text: String) -> String {
    "\"\(text)\""
}

public extension TraceDiff {
    /// Extension mode: reclassify divergences the intent spec declared as `.intended`, then re-derive
    /// the verdict from the residual (gating, collateral) divergences. `Intent.none` is a no-op
    /// (parity mode) — every divergence stays collateral and the verdict is unchanged.
    ///
    /// `inputs` are the probe's recorded seam reads, which a `.when(_:is:)` condition matches
    /// against; without them no conditioned declaration can match.
    ///
    /// Also records `unobservedIntent`: the declarations that matched nothing *in this comparison*.
    /// For a single diff that is the finished fact; a sweep that compares many probes intersects the
    /// per-probe sets (a declaration is observed if any probe matched it) and overwrites the
    /// reported diff's copy — see `Spec.verify`.
    func classified(against intent: Intent, inputs: ProbeInputs? = nil) -> TraceDiff {
        var result = self
        var observed = Set<String>()
        let declarations = intent.declarations
        for index in result.divergences.indices {
            var matched = false
            for declaration in declarations where declaration.matches(result.divergences[index], inputs) {
                observed.insert(declaration.text)
                matched = true
            }
            if matched {
                result.divergences[index].classification = .intended
            }
        }
        result.unobservedIntent = declarations.map(\.text).filter { !observed.contains($0) }
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
