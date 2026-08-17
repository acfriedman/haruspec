import Foundation

/// The category of a recorded behavioral event. These are the "observable behavior" primitives:
/// method-entry/exit, notifications, state changes, and timed intervals.
public enum EventKind: String, Codable, Sendable, CaseIterable {
    case call // function / method entry (payload = arguments)
    case ret // function / method return (payload = return value)
    case notification // a posted notification / broadcast side effect
    case stateChange // an observable property / state mutation
    case signpost // a timed interval (durationTicks is set)
    case marker // a payload-free temporal signpost at a product milestone (semantic tier)
    case effect // an outbound call to a spied collaborator — an observable side effect (semantic tier)
    case custom // app-defined telemetry an application wants to pin (droppable via ignoredKinds)
    case snapshot // a property value the harness read back at the capture boundary (semantic tier)
}

/// How much of the subject's property-mutation timeline this trace's capture could see — a fact about
/// the *instrumentation*, carried on the trace so the diff never compares one side's writes against a
/// side that structurally could not record its own.
///
///  - `.full`: every committed write to a stored property is recorded (`@Traced`'s observer
///    instrumentation).
///  - `.boundary`: only writes that crossed the wrapper are recorded (`@TracedForwarder`'s generated
///    setter — the wrapped object's *internal* writes are invisible to it).
///  - `.none`: the capture declared nothing about property writes (hand-built traces, older captures).
///
/// The mutation-*order* comparison requires `.full` on both sides; anything less drops `.stateChange`
/// events from the diff and the verdict's qualification says so. Snapshots (`.snapshot`) are read by
/// the harness itself, so they compare under every capability.
public enum MutationCapture: String, Codable, Sendable {
    case none
    case boundary
    case full
}

/// Which durability tier an event belongs to.
///
/// The distinction answers the code-symbol *rename drift* problem. The **structural** tier is internal
/// call mechanics — method entry/exit and timing — labeled by code symbols, so it churns whenever you
/// rename or restructure (e.g. an imperative → reactive migration). The **semantic** tier is the
/// observable product behavior — notifications, KVO/state changes, payload-free markers, and outbound
/// calls recorded at an injected collaborator seam (a real effect leaving the SUT across a declared
/// boundary) — labeled by domain concepts / stable public APIs, so it survives refactors and is the
/// durable contract. Tolerances
/// can gate on one
/// tier and treat the other as advisory or ignored (see `StructuralComparison`).
public enum EventTier: String, Codable, Sendable {
    case structural // internal call mechanics (calls / returns / timing) — code-symbol-named, fragile
    case semantic // observable product behavior (notifications, state, markers) — the durable contract
}

/// The **isolation context** an event was recorded on — run-stable and nominal.
///
/// Not a thread. An OS thread is the wrong unit under Swift concurrency: one cooperative-pool thread
/// serves an actor, a nonisolated function and several dispatch queues in the same run, and
/// consecutive tasks hop between threads freely. Numbering threads in first-seen order therefore
/// conflates distinct domains *and* renumbers them run to run — which is precisely the nondeterminism
/// canonicalization exists to remove.
///
/// So identity is taken **nominally**, from what the code declares rather than from where it landed:
/// the isolating actor when there is one, the dispatch queue the work was genuinely handed to
/// otherwise, and `ambient` when the code declares nothing at all.
public enum ConcurrencyDomain: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The main actor / main thread.
    case main
    /// An actor instance: its nominal type, plus a symbolic instance id (first-seen, shared with the
    /// event `subject` numbering) so two `Ledger`s stay distinguishable.
    case actor(String, instance: Int)
    /// A named dispatch queue, keyed by its label — nominal and stable by construction.
    ///
    /// `serial` is the queue's **ordering discipline**, and it is part of the identity on purpose: a
    /// serial queue's order is a runtime guarantee the code may rely on, a concurrent queue's is
    /// whichever block finished first. The discipline deciding whether a projection compares this
    /// domain as a sequence or as a multiset, and a discipline *change* on the same label reading as
    /// a different domain (so the migration machinery reports it), both fall out of it living here.
    case queue(String, serial: Bool)
    /// The code declares **no isolation of its own** — a plain type, a nonisolated function, an
    /// unstructured task. It ran wherever its caller happened to be.
    ///
    /// This is deliberately *not* "the cooperative pool" or "the main thread". Answering with where the
    /// work landed would make the harness part of the measurement: the same plain class reads `main`
    /// when a synchronous test calls it and `pool` when an async one does, having changed in no way.
    /// That is the `worker-N` failure one level up. Ambient says the only true thing available — the
    /// code names no domain — and says it identically from every caller.
    ///
    /// Unordered, for the same reason `pool` was: there is no single serial context to order within.
    case ambient

    public var description: String {
        switch self {
        case .main: "main"
        case let .actor(type, instance): "actor:\(type)#\(instance)"
        case let .queue(label, serial: true): "queue(serial):\(label)"
        case let .queue(label, serial: false): "queue(concurrent):\(label)"
        case .ambient: "ambient"
        }
    }

    /// Whether events in this domain have a meaningful relative order. `main`, an actor, and a serial
    /// queue give mutual exclusion, so their order is a runtime guarantee. A concurrent queue's order
    /// is whichever block finished first, and `ambient` has no single context to be ordered within.
    public var isOrdered: Bool {
        switch self {
        case .main, .actor: true
        case let .queue(_, serial): serial
        case .ambient: false
        }
    }

    /// The name an author refers to this domain by — a queue's bare label, anything else its
    /// description. This is what `Intent.expectedOrderingRelaxations` matches against, so declaring
    /// "com.emporium.cart" doesn't require spelling the engine's `queue(serial):` prefix.
    public var declaredName: String {
        if case let .queue(label, _) = self {
            return label
        }
        return description
    }
}

extension ConcurrencyDomain: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "main": self = .main
        case "ambient": self = .ambient
        default:
            // A bare `queue:` (pre-discipline) is rejected rather than coerced: guessing serial would
            // silently turn a stale artifact's noise into a contract. The plan schema gate says
            // "re-record" first, so this fires only on a hand-mangled trace.
            if raw.hasPrefix("queue(serial):") {
                self = .queue(String(raw.dropFirst("queue(serial):".count)), serial: true)
            } else if raw.hasPrefix("queue(concurrent):") {
                self = .queue(String(raw.dropFirst("queue(concurrent):".count)), serial: false)
            } else if raw.hasPrefix("actor:"),
                      case let body = raw.dropFirst("actor:".count),
                      let hash = body.lastIndex(of: "#"),
                      let instance = Int(body[body.index(after: hash)...]) {
                self = .actor(String(body[..<hash]), instance: instance)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized ConcurrencyDomain \"\(raw)\""
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A single recorded unit of ground-truth behavior.
///
/// Everything on this struct is already canonical-by-construction: `seq` is a logical clock (not a
/// wall timestamp), `subject` is a symbolic identity (not a pointer), and `domain` is nominal.
public struct TraceEvent: Sendable, Equatable {
    /// Logical clock — monotonically increasing per recorder. Diffing orders by this, never by wall time.
    public var seq: Int
    public var kind: EventKind
    /// Stable identifier for the event, e.g. `"CartService.checkout"` or a notification name.
    public var label: String
    public var domain: ConcurrencyDomain
    /// Symbolic object identity (first-seen order), or nil for free functions / static context.
    public var subject: Int?
    /// Arguments / return value / notification userInfo, canonicalized.
    public var payload: CanonicalValue?
    /// Duration for `.signpost` intervals. A *tolerant* field: only compared against declared budgets.
    public var durationTicks: Int64?
    /// Call-nesting depth (informational; helps render/understand a trace).
    public var depth: Int
    /// Durability tier. Defaults to `.structural` (call mechanics); observable side effects
    /// (notifications, state changes) and markers are `.semantic`.
    public var tier: EventTier

    /// The `seq` of the traced call that *spawned* this work, when it arrived by a dispatch or a task
    /// rather than by being called — a **happens-before edge**, and the only kind the runtime hands
    /// over for free.
    ///
    /// Set on the first event inside a seam-wrapped block, because program order carries the rest: the
    /// whole block happens after the enqueue, so one edge to its first event says all of it. The cause
    /// is the enclosing *call*, not the last event recorded, because "which unit of work spawned this"
    /// is both more meaningful and more stable than "what happened to be recorded a moment before".
    public var spawnedBy: Int?

    public init(
        seq: Int,
        kind: EventKind,
        label: String,
        domain: ConcurrencyDomain = .main,
        subject: Int? = nil,
        payload: CanonicalValue? = nil,
        durationTicks: Int64? = nil,
        depth: Int = 0,
        tier: EventTier = .structural,
        spawnedBy: Int? = nil
    ) {
        self.seq = seq
        self.kind = kind
        self.label = label
        self.domain = domain
        self.subject = subject
        self.payload = payload
        self.durationTicks = durationTicks
        self.depth = depth
        self.tier = tier
        self.spawnedBy = spawnedBy
    }
}

extension TraceEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case seq, kind, label, domain, subject, payload, durationTicks, depth, tier, spawnedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        kind = try container.decode(EventKind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        domain = try container.decode(ConcurrencyDomain.self, forKey: .domain)
        subject = try container.decodeIfPresent(Int.self, forKey: .subject)
        payload = try container.decodeIfPresent(CanonicalValue.self, forKey: .payload)
        durationTicks = try container.decodeIfPresent(Int64.self, forKey: .durationTicks)
        depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        tier = try container.decodeIfPresent(EventTier.self, forKey: .tier) ?? .structural
        spawnedBy = try container.decodeIfPresent(Int.self, forKey: .spawnedBy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encode(domain, forKey: .domain)
        try container.encodeIfPresent(subject, forKey: .subject)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encodeIfPresent(durationTicks, forKey: .durationTicks)
        try container.encode(depth, forKey: .depth)
        if tier != .structural {
            try container.encode(tier, forKey: .tier)
        } // omit the default for clean JSON
        try container.encodeIfPresent(spawnedBy, forKey: .spawnedBy)
    }
}

/// A captured golden behavior trace: the ordered sequence of events from one spec run.
public struct Trace: Sendable, Equatable {
    public var name: String
    public var schemaVersion: Int
    /// What the capture could see of property writes (see `MutationCapture`). `.none` for hand-built
    /// traces and captures that declared nothing — absence is a statement here, not a gap.
    public var mutationCapture: MutationCapture
    public var events: [TraceEvent]

    public init(
        name: String,
        schemaVersion: Int = 1,
        mutationCapture: MutationCapture = .none,
        events: [TraceEvent]
    ) {
        self.name = name
        self.schemaVersion = schemaVersion
        self.mutationCapture = mutationCapture
        self.events = events
    }
}

extension Trace: Codable {
    enum CodingKeys: String, CodingKey {
        case name, schemaVersion, mutationCapture, events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // Absent means the capture declared nothing — a genuine `.none`, not a migration shim.
        mutationCapture = try container.decodeIfPresent(MutationCapture.self, forKey: .mutationCapture) ?? .none
        events = try container.decode([TraceEvent].self, forKey: .events)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        if mutationCapture != .none {
            try container.encode(mutationCapture, forKey: .mutationCapture)
        } // omit the default for clean JSON
        try container.encode(events, forKey: .events)
    }
}

public extension Trace {
    /// Deterministic on-disk form: sorted keys + stable formatting so golden files diff cleanly in git.
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    func jsonData() throws -> Data {
        try Self.canonicalEncoder().encode(self)
    }

    func write(to url: URL) throws {
        try jsonData().write(to: url)
    }

    init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Trace.self, from: jsonData)
    }

    init(contentsOf url: URL) throws {
        try self.init(jsonData: Data(contentsOf: url))
    }
}
