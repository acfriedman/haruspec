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
        declarations.contains { $0.matches(divergence) }
    }

    /// A value-mismatch `detail` reads `"<path>: baseline=… candidate=…"`; match on that leading path.
    private static func fieldMatches(_ field: String, _ detail: String) -> Bool {
        let path = detail.range(of: ": ").map { String(detail[..<$0.lowerBound]) } ?? detail
        return path == field || path.hasPrefix("\(field).") || path.hasPrefix("\(field)[")
    }
}

/// One atomic declaration inside an `Intent` — the unit "declared but not observed" is measured in.
///
/// `text` is the declaration's DSL spelling (`Changes("Search.query")`), so a warning about a dead
/// declaration names exactly the line to delete.
struct IntentDeclaration: Sendable {
    let text: String
    let matches: @Sendable (Divergence) -> Bool
}

extension Intent {
    /// The intent exploded into its atomic declarations, each pairing a matcher with its DSL spelling.
    ///
    /// `declares(_:)` is a fold over this list, and the unobserved-intent check is its
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
        for label in expectedNewEvents {
            atoms.append(IntentDeclaration(text: "Emits(\(quoted(label)))") {
                $0.kind == .unexpectedEvent && $0.label == label
            })
        }
        for label in expectedRemovedEvents {
            atoms.append(IntentDeclaration(text: "Omits(\(quoted(label)))") {
                $0.kind == .missingEvent && $0.label == label
            })
        }
        // Per-field atoms: declaring one field never excuses — and is never excused by — another.
        for (label, fields) in expectedValueChanges.sorted(by: { $0.key < $1.key }) {
            if fields.isEmpty {
                atoms.append(IntentDeclaration(text: "Changes(\(quoted(label)))") {
                    $0.kind == .valueMismatch && $0.label == label
                })
            }
            for field in fields {
                atoms.append(IntentDeclaration(text: "Changes(\(quoted(label)), field: \(quoted(field)))") {
                    $0.kind == .valueMismatch && $0.label == label && Self.fieldMatches(field, $0.detail)
                })
            }
        }
        for domain in expectedOrderingRelaxations {
            atoms.append(IntentDeclaration(text: "Relaxes(orderingOf: \(domain.dslText))") {
                $0.kind == .orderingRelaxed && domain.matches($0.fromDomain)
            })
        }
        for label in expectedOrderingLosses {
            atoms.append(IntentDeclaration(text: "Drops(synchronizationOf: \(quoted(label)))") {
                $0.kind == .orderingLost && $0.label == label
            })
        }
        for label in expectedOrderingAdditions {
            atoms.append(IntentDeclaration(text: "Awaits(\(quoted(label)))") {
                $0.kind == .orderingAdded && $0.label == label
            })
        }
        for label in expectedReorders {
            atoms.append(IntentDeclaration(text: "Reorders(\(quoted(label)))") {
                $0.kind == .reordered && $0.label == label
            })
        }
        for move in expectedDomainMigrations {
            let scope = move.labels.isEmpty
                ? "everythingFrom: "
                : move.labels.map(quoted).joined(separator: ", ") + ", from: "
            atoms.append(IntentDeclaration(
                text: "Moves(\(scope)\(move.origin.dslText), to: \(move.destination.dslText))"
            ) {
                $0.kind == .domainMigration
                    && move.matches(label: $0.label, from: $0.fromDomain, to: $0.toDomain)
            })
        }
        return atoms
    }
}

public extension Intent {
    /// Every atomic declaration's DSL spelling, in `declarations` order — the list tooling prints
    /// when it names what an intent claims.
    var declarationTexts: [String] {
        declarations.map(\.text)
    }
}

public extension Divergence {
    /// The declaration that would mark this divergence intended — the exact line the teaching loop
    /// offers on a red verdict, and a line `IntentGrammar` parses back.
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
            // The detail's leading path is the changed field; suggest exactly it, so the pasted
            // declaration is as narrow as what was observed.
            let path = detail.range(of: ": ").map { String(detail[..<$0.lowerBound]) } ?? ""
            return path.isEmpty
                ? "Changes(\(quoted(label)))"
                : "Changes(\(quoted(label)), field: \(quoted(path)))"
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
    /// Also records `unobservedIntent`: the declarations that matched nothing *in this comparison*.
    /// For a single diff that is the finished fact; a sweep that compares many probes intersects the
    /// per-probe sets (a declaration is observed if any probe matched it) and overwrites the
    /// reported diff's copy — see `Spec.verify`.
    func classified(against intent: Intent) -> TraceDiff {
        var result = self
        var observed = Set<String>()
        let declarations = intent.declarations
        for index in result.divergences.indices {
            var matched = false
            for declaration in declarations where declaration.matches(result.divergences[index]) {
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
