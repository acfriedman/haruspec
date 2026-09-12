import Foundation

// The declaration DSL over `Intent` — the `.vary { }` idea applied to intent. Each constructor is a
// sentence about *the port being checked*: it moves work between domains, relaxes an ordering,
// awaits what was fire-and-forget, emits a new event. The builder folds them into one `Intent`:
//
//     declaring: Intent {
//         Moves("Inventory.reserve", from: .queue("com.emporium.cart"), to: .actor(SwiftCartActor.self))
//         Relaxes(orderingOf: .queue("com.emporium.cart"))
//         Awaits("Inventory.reserve")
//     }

/// How an author names an isolation domain in a declaration — deliberately *coarser* than the
/// engine's `ConcurrencyDomain`, because a declaration should not require engine bookkeeping:
///
///  - `.queue(label)` matches the queue whichever ordering discipline it has. Declaring a move is
///    about *where the work went*; a discipline change is a separate fact with its own gate
///    (`orderingRelaxed`), so nothing is lost by not spelling it here.
///  - `.actor(...)` matches every instance of the type. First-seen instance numbering is the
///    engine's, not the author's.
public enum DomainName: Sendable, Equatable {
    case main
    case ambient
    /// A dispatch or operation queue, by the label its code declared.
    case queue(String)
    /// An actor, by type name — `.actor("SwiftCartActor")`, or `.actor(SwiftCartActor.self)`.
    case actor(String)

    /// The type-safe spelling: `.actor(SwiftCartActor.self)`.
    public static func actor(_ type: Any.Type) -> DomainName {
        .actor(String(describing: type))
    }

    /// Whether this name matches a recorded domain's description (`Divergence.fromDomain`/`toDomain`).
    func matches(_ description: String?) -> Bool {
        guard let description else {
            return false
        }
        switch self {
        case .main:
            return description == "main"
        case .ambient:
            return description == "ambient"
        case let .queue(label):
            return description == "queue(serial):\(label)" || description == "queue(concurrent):\(label)"
        case let .actor(type):
            return Self.droppingInstance(description) == "actor:\(type)"
        }
    }

    /// `actor:SwiftCartActor#3` → `actor:SwiftCartActor`; everything else unchanged.
    static func droppingInstance(_ description: String) -> String {
        guard description.hasPrefix("actor:"), let hash = description.lastIndex(of: "#") else {
            return description
        }
        return String(description[..<hash])
    }

    /// The declaration spelling — `.queue("com.emporium.cart")`.
    ///
    /// Used by unobserved-intent warnings, grammar errors, and the report's suggested
    /// declarations, so every rendering is a line `IntentGrammar` parses back.
    public var dslText: String {
        switch self {
        case .main: ".main"
        case .ambient: ".ambient"
        case let .queue(label): ".queue(\"\(label)\")"
        case let .actor(type): ".actor(\"\(type)\")"
        }
    }

    /// The declaration-level name of a domain as a divergence records it —
    /// `"queue(serial):com.emporium.cart"` → `.queue("com.emporium.cart")`.
    ///
    /// Discipline and instance numbering drop away, so a report can suggest the declaration that
    /// would match what it saw.
    public init?(recorded: String) {
        switch recorded {
        case "main": self = .main
        case "ambient": self = .ambient
        default:
            for prefix in ["queue(serial):", "queue(concurrent):"] where recorded.hasPrefix(prefix) {
                self = .queue(String(recorded.dropFirst(prefix.count)))
                return
            }
            guard recorded.hasPrefix("actor:") else { return nil }
            self = .actor(String(Self.droppingInstance(recorded).dropFirst("actor:".count)))
        }
    }
}

extension DomainName: Codable {
    /// One readable string per name — `"main"`, `"ambient"`, `"queue:com.emporium.cart"`,
    /// `"actor:SwiftCartActor"` — with no discipline or instance detail, matching what a declaration
    /// means. Unrecognized spellings are refused, never coerced.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "main": self = .main
        case "ambient": self = .ambient
        default:
            if raw.hasPrefix("queue:") {
                self = .queue(String(raw.dropFirst("queue:".count)))
            } else if raw.hasPrefix("actor:") {
                self = .actor(String(raw.dropFirst("actor:".count)))
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized domain name \"\(raw)\""
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw = switch self {
        case .main: "main"
        case .ambient: "ambient"
        case let .queue(label): "queue:\(label)"
        case let .actor(type): "actor:\(type)"
        }
        try container.encode(raw)
    }
}

/// One declared fact about the port being checked. Conformers fold themselves into the `Intent`
/// the builder is assembling.
public protocol Intention: Sendable {
    func apply(to intent: inout Intent)
}

@resultBuilder
public enum IntentionsBuilder {
    public static func buildBlock(_ intentions: (any Intention)...) -> [any Intention] {
        intentions
    }
}

public extension Intent {
    /// Builds an intent from declarations that read as sentences about the port:
    ///
    ///     Intent {
    ///         Moves("Inventory.reserve", from: .queue("com.emporium.cart"), to: .actor(SwiftCartActor.self))
    ///         Awaits("Inventory.reserve")
    ///     }
    init(@IntentionsBuilder _ intentions: () -> [any Intention]) {
        self.init()
        for intention in intentions() {
            intention.apply(to: &self)
        }
    }
}

// MARK: - The intentions

/// The port moves work from one isolation domain to another — `domainMigration`.
///
/// **Label-scoped by default**: a declaration names the events it moves, and only those events are
/// excused — a sixth event migrating between the same domains later gates again. A declaration is a
/// *standing* excuse, and breadth must not happen by accident, so the blanket form is its own
/// explicit, greppable spelling: `Moves(everythingFrom:to:)` — for the genuine wholesale port, whose
/// claim really is "everything this domain did now happens there."
public struct Moves: Intention {
    /// The event labels this declaration covers; empty means every label (the wholesale form).
    let labels: [String]
    let origin: DomainName
    let destination: DomainName

    /// Moves these events — `Moves("Inventory.reserve", "CartDidChange", from: …, to: …)`. At least
    /// one label, by construction: breadth is never the default.
    public init(_ first: String, _ rest: String..., from origin: DomainName, to destination: DomainName) {
        labels = [first] + rest
        self.origin = origin
        self.destination = destination
    }

    /// The wholesale port's spelling: every event that migrates between this pair is intended.
    /// The word is the warning — reach for the labeled form unless "everything" is literally true.
    public init(everythingFrom origin: DomainName, to destination: DomainName) {
        labels = []
        self.origin = origin
        self.destination = destination
    }

    public func apply(to intent: inout Intent) {
        intent.expectedDomainMigrations.append(
            Intent.DomainMove(labels: labels, from: origin, to: destination)
        )
    }
}

/// The port drops an ordered domain's ordering guarantee — `orderingRelaxed`. The serial-queue →
/// task-group migration is the canonical case.
public struct Relaxes: Intention {
    let domain: DomainName

    public init(orderingOf domain: DomainName) {
        self.domain = domain
    }

    public func apply(to intent: inout Intent) {
        intent.expectedOrderingRelaxations.append(domain)
    }
}

/// The port drops the happens-before constraint on an event — `orderingLost`, by the spawned
/// event's label.
public struct Drops: Intention {
    let label: String

    public init(synchronizationOf label: String) {
        self.label = label
    }

    public func apply(to intent: inout Intent) {
        intent.expectedOrderingLosses.append(label)
    }
}

/// The port newly synchronizes an event the baseline left concurrent — `orderingAdded`. The awaited
/// port of fire-and-forget work is the canonical case, and the name.
public struct Awaits: Intention {
    let label: String

    public init(_ label: String) {
        self.label = label
    }

    public func apply(to intent: inout Intent) {
        intent.expectedOrderingAdditions.append(label)
    }
}

/// The port deliberately reorders an event whose order is compared — `reordered`, by label. The
/// canonical case is an observed property's write under `MutationOrderPolicy.gating`: a port that
/// computes its state in a different order names the writes it moves, and only those.
public struct Reorders: Intention {
    let labels: [String]

    /// At least one label, by construction — a blanket reorder excuse would pre-excuse every future
    /// ordering change on the subject.
    public init(_ first: String, _ rest: String...) {
        labels = [first] + rest
    }

    public func apply(to intent: inout Intent) {
        intent.expectedReorders.append(contentsOf: labels)
    }
}

/// The change emits an event the baseline never had — a declared feature, not an accident.
///
/// Narrow it to the probes it belongs in: `Emits("Inventory.reserve").when("add.quantity", is: 1)`.
public struct Emits: Intention {
    var declaration: Intent.EventChange

    public init(_ label: String) {
        declaration = Intent.EventChange(label)
    }

    /// Only in a probe whose recorded reads of `seam` all returned `value`.
    public func when(_ seam: String, is value: CanonicalValue) -> Emits {
        var narrowed = self
        narrowed.declaration.conditions.append(InputCondition(seam: seam, is: value))
        return narrowed
    }

    public func apply(to intent: inout Intent) {
        intent.expectedNewEvents.append(declaration)
    }
}

/// The change omits an event the baseline produced — a declared removal.
///
/// Narrow it to the probes it belongs in: `Omits("Inventory.reserve").when("add.quantity", is: 0)`.
public struct Omits: Intention {
    var declaration: Intent.EventChange

    public init(_ label: String) {
        declaration = Intent.EventChange(label)
    }

    /// Only in a probe whose recorded reads of `seam` all returned `value`.
    public func when(_ seam: String, is value: CanonicalValue) -> Omits {
        var narrowed = self
        narrowed.declaration.conditions.append(InputCondition(seam: seam, is: value))
        return narrowed
    }

    public func apply(to intent: inout Intent) {
        intent.expectedRemovedEvents.append(declaration)
    }
}

/// The subject reaches an effect channel the capture cannot see, and the author accepts that — the
/// only exit from a capture-completeness gate: `Accepts(uncaptured: "Timer / RunLoop")`.
///
/// Weaker than it looks on purpose. Every other intention excuses a divergence the diff *found*;
/// this one excuses a whole channel the diff could never have found, so it does not remove the
/// channel from the verdict — it moves it from "gates" to "named blind spot on the report," which is
/// what the README disclaimer promises a reader. Named by channel, so accepting `Timer` says nothing
/// about Combine.
public struct Accepts: Intention {
    let channel: String

    public init(uncaptured channel: String) {
        self.channel = channel
    }

    public func apply(to intent: inout Intent) {
        intent.acceptedBlindSpots.append(channel)
    }
}

/// The change alters an event's payload — a specific field, or (with no fields named) any of them.
/// Declaring one field does NOT excuse a change to another field of the same event.
///
/// Say *how* it changes and the declaration becomes a tripwire for everything else:
///
///     Changes("CheckoutDidComplete", field: "totalCents").to(11363)
///     Changes("Receipt", field: "discountCents").increases()
///     Changes("LoyaltyPointsEarned", field: "points").within(1 ... 64)
///     Changes("Receipt", field: "discountCents").when("applyPromo.code", is: "SAVE10")
///
/// One value relation per declaration; a second is a contradiction and traps.
public struct Changes: Intention {
    let label: String
    let fields: [String]
    var relation: ValueRelation?
    var conditions: [InputCondition] = []

    public init(_ label: String, field fields: String...) {
        self.label = label
        self.fields = fields
    }

    /// The new value is exactly `value` — a scalar, the only shape the grammar can spell back.
    public func to(_ value: CanonicalValue) -> Changes {
        precondition(value.isScalar, "Changes(…).to(_:) takes a scalar, not \(value.canonicalString)")
        return narrowed(.to(value))
    }

    /// The value went up.
    public func increases() -> Changes {
        narrowed(.increases)
    }

    /// The value went down.
    public func decreases() -> Changes {
        narrowed(.decreases)
    }

    /// The new value lies in `range`.
    public func within(_ range: ClosedRange<Int>) -> Changes {
        narrowed(.within(Double(range.lowerBound) ... Double(range.upperBound)))
    }

    /// The new value lies in `range`.
    public func within(_ range: ClosedRange<Double>) -> Changes {
        narrowed(.within(range))
    }

    /// Only in a probe whose recorded reads of `seam` all returned `value`.
    public func when(_ seam: String, is value: CanonicalValue) -> Changes {
        var narrowed = self
        narrowed.conditions.append(InputCondition(seam: seam, is: value))
        return narrowed
    }

    private func narrowed(_ relation: ValueRelation) -> Changes {
        precondition(
            self.relation == nil,
            "Changes(\"\(label)\") already declares \(self.relation!.dslText); one value relation per declaration"
        )
        var narrowed = self
        narrowed.relation = relation
        return narrowed
    }

    public func apply(to intent: inout Intent) {
        let fields: [String?] = fields.isEmpty ? [nil] : fields
        for field in fields {
            intent.expectedValueChanges.append(
                Intent.ValueChange(label, field: field, relation: relation, when: conditions)
            )
        }
    }
}
