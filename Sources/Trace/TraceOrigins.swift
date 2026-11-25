import Foundation
import HaruspecCore

/// Where a traced label's behavior is **declared** — the source map an audit needs to know which files
/// it must read before it can claim a verdict saw every effect channel.
///
/// A verdict's `coveredClasses` names *labels* (`"Cart"`), and a label is deliberately decoupled from
/// the type carrying it — `@Haruspec protocol Cart`'s forwarder wraps the Obj-C baseline and
/// `SwiftCartActor` alike. So a label
/// cannot be resolved to a file by searching for its own name: two ports can share one label, and
/// neither has to be named after it. The macro is the one place that knows both halves at once, so it
/// stamps the origin at expansion time (a forwarder reads the wrapped type as it runs) and the
/// recorder collects it when the method actually runs — which makes the origin set exactly the
/// *reached* set, the same condition that puts a class in `coveredClasses`.
public struct TraceOrigin: Codable, Hashable, Sendable, Comparable {
    /// The trace label the events carry (`"Cart"`) — the join key back to `coveredClasses`.
    public let label: String
    /// The type that declares the behavior: a forwarder's wrapped class, or a double's own.
    public let symbol: String?
    /// The declaring file as a `#fileID` path (`"LegacyApp/SwiftCartActor.swift"`), or `nil` where
    /// there is no Swift source to read — an Obj-C class behind a forwarder.
    ///
    /// `#fileID` rather than `#filePath` on purpose: an absolute path is machine-specific, and verdicts
    /// are compared char-for-char across machines (the CI freshness guard *is* that comparison).
    /// Resolving a fileID against a checkout is the audit step's job, where a repo root is in hand.
    public let source: String?

    public init(label: String, symbol: String? = nil, source: String? = nil) {
        self.label = label
        self.symbol = symbol
        self.source = source
    }

    /// Sorted so a verdict's origin list is deterministic — the same reason traces canonicalize.
    public static func < (lhs: TraceOrigin, rhs: TraceOrigin) -> Bool {
        (lhs.label, lhs.symbol ?? "", lhs.source ?? "") < (rhs.label, rhs.symbol ?? "", rhs.source ?? "")
    }
}

/// Accumulates the origins reached during one verification, across every capture it drives.
///
/// A reference type because the union spans several recorders — the golden template, each probe, the
/// candidate — and the qualification wants all of them. Locked rather than actor-isolated: it is
/// written from whatever thread a traced method happens to run on, including a structured child task
/// running beside its siblings.
public final class OriginCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var origins: Set<TraceOrigin> = []
    private var injected: Set<String> = []
    private var held: Set<String> = []

    public init() {}

    public func note(_ origin: TraceOrigin) {
        lock.lock(); defer { lock.unlock() }
        origins.insert(origin)
    }

    /// Records that `label` is an injected collaborator boundary in this verification — declared by
    /// the act of injection itself (`SeamContext.inject`), not restated as data anywhere.
    public func noteInjected(label: String) {
        lock.lock(); defer { lock.unlock() }
        injected.insert(label)
    }

    /// Records that the capture held work through a stand-in it handed the subject.
    ///
    /// - Parameter standIn: The stand-in's name, as `HeldStandIn` spells it.
    ///
    /// A `context.scheduler` or `context.operationQueue` notes itself here, so the audit can tell a
    /// reach through it from a reach around the capture.
    public func noteHeldStandIn(_ standIn: String) {
        lock.lock(); defer { lock.unlock() }
        held.insert(standIn)
    }

    /// The stand-ins the capture held work through, sorted.
    public var heldStandIns: [String] {
        lock.lock(); defer { lock.unlock() }
        return held.sorted()
    }

    public var snapshot: [TraceOrigin] {
        lock.lock(); defer { lock.unlock() }
        return origins.sorted()
    }

    /// The labels handed in as collaborators. Everything else reached under capture is the subject —
    /// which is exactly the completeness audit's denominator.
    public var injectedLabels: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return injected
    }
}

/// The ambient collector a `TraceRecorder` picks up when it is built.
///
/// Bound once per verification rather than passed down, for the same reason ``TraceContext/current`` is:
/// the capture primitive is called from half a dozen places and none of them should have to carry an
/// audit concern. A task-local also scopes it per verification, so specs running in parallel (the
/// default under swift-testing) cannot pool their origins into each other's verdicts.
public enum TraceOrigins {
    @TaskLocal public static var collector: OriginCollector?
}

/// A type that knows the trace label its events carry. Conformance is emitted on every stamped
/// forwarder and double, so any instrumented instance can state its own label — which is what lets an
/// injection point (``SeamContext/inject``) register a collaborator without anyone typing the label a
/// second time.
public protocol TraceLabeled {
    var traceLabel: String { get }
}
