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
/// engine's `ConcurrencyDomain`, because a declaration should not require engine bookkeeping.
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

    /// Returns whether this name matches a recorded domain's description.
    ///
    /// - Parameter description: A recorded domain's description, as a divergence's
    ///   ``Divergence/fromDomain`` or `toDomain` carries it; `nil` when the divergence has none.
    /// - Returns: `true` when `description` names this domain, a queue under either ordering
    ///   discipline and an actor under any instance; `false` for `nil`.
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

    /// `actor:SwiftCartActor#3` → `actor:SwiftCartActor`; everything else unchanged.
    static func droppingInstance(_ description: String) -> String {
        guard description.hasPrefix("actor:"), let hash = description.lastIndex(of: "#") else {
            return description
        }
        return String(description[..<hash])
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
    /// Builds an intent from declarations that read as sentences about the port.
    ///
    /// - Parameter intentions: The declarations, one per line of the builder, in the order written;
    ///   an empty builder declares nothing, as ``Intent/none`` does.
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
    var scope: OpScope?

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

    /// Only under the declared op `op` — `Moves(…).only(in: "checkout")`.
    public func only(in op: String) -> Moves {
        var narrowed = self
        narrowed.scope = .only(in: op)
        return narrowed
    }

    public func apply(to intent: inout Intent) {
        intent.expectedDomainMigrations.append(
            Intent.DomainMove(labels: labels, from: origin, to: destination, scope: scope)
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

/// The port deliberately reorders an event whose order is compared — `reordered`, by label: a port
/// that emits its effects in a different order names the events it moves, and only those.
///
/// Say which way it moved and the declaration becomes a tripwire for every other move:
/// `Reorders("Archive.archive", before: "CartDidChange")` holds only for an event that now sits
/// before the anchor and sat after it in the baseline (within the same op, when known).
public struct Reorders: Intention {
    let labels: [String]
    let position: Position?

    /// At least one label, by construction — a blanket reorder excuse would pre-excuse every future
    /// ordering change on the subject.
    public init(_ first: String, _ rest: String...) {
        labels = [first] + rest
        position = nil
    }

    /// The events now sit before `anchor`, having sat after it.
    public init(_ first: String, _ rest: String..., before anchor: String) {
        labels = [first] + rest
        position = .before(anchor)
    }

    /// The events now sit after `anchor`, having sat before it.
    public init(_ first: String, _ rest: String..., after anchor: String) {
        labels = [first] + rest
        position = .after(anchor)
    }

    public func apply(to intent: inout Intent) {
        intent.expectedReorders += labels.map { Intent.Reorder($0, position: position) }
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
