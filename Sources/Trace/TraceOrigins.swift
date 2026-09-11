import Foundation
import HaruspecCore

/// Where a traced label's behavior is **declared** — the source map an audit needs to know which files
/// it must read before it can claim a verdict saw every effect channel.
///
/// A verdict's `coveredClasses` names *labels* (`"Cart"`), and a label is deliberately decoupled from
/// the type carrying it — `@Traced("Cart") final class SwiftCartActor`, and
/// `@TracedForwarder(label: "Cart")` wrapping the Obj-C baseline. So a label
/// cannot be resolved to a file by searching for its own name: two ports can share one label, and
/// neither has to be named after it. The macro is the one place that knows both halves at once, so it
/// stamps the origin at expansion time (a forwarder reads the wrapped type as it runs) and the
/// recorder collects it when the method actually runs — which makes the origin set exactly the
/// *reached* set, the same condition that puts a class in `coveredClasses`.
public struct TraceOrigin: Codable, Hashable, Sendable, Comparable {
    /// The trace label the events carry (`"Cart"`) — the join key back to `coveredClasses`.
    public let label: String
    /// The type that declares the behavior: the `@Traced` type, or a forwarder's wrapped class.
    public let symbol: String?
    /// The declaring file as a `#fileID` path (`"LegacyApp/SwiftCartActor.swift"`), or `nil` where
    /// there is no Swift source to read — an Obj-C class behind a `@TracedForwarder`.
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
/// written from whatever thread a traced method happens to run on, including a block the GCD seam
/// handed to a thread with no task at all.
public final class OriginCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var origins: Set<TraceOrigin> = []
    private var injected: Set<String> = []

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
/// Bound once per verification rather than passed down, for the same reason `TraceContext.current` is:
/// the capture primitive is called from half a dozen places and none of them should have to carry an
/// audit concern. A task-local also scopes it per verification, so specs running in parallel (the
/// default under swift-testing) cannot pool their origins into each other's verdicts.
public enum TraceOrigins {
    @TaskLocal public static var collector: OriginCollector?
}

/// A type that knows the trace label its events carry. Conformance is emitted by `@Traced` and
/// `@TracedForwarder`, so any instrumented instance can state its own label — which is what lets an
/// injection point (`SeamContext.inject`) register a collaborator without anyone typing the label a
/// second time.
public protocol TraceLabeled {
    var traceLabel: String { get }
}

/// A type that states how much of its property-write timeline its instrumentation records — the
/// per-side fact the mutation-order diff refuses to guess (see `MutationCapture`). The capture reads
/// it off the system under test and stamps the trace; a system declaring nothing captures `.none`.
public protocol MutationCapturing {
    var mutationCapture: MutationCapture { get }
}

/// The `@Traced` conformance: observer instrumentation on every stored property, so the whole write
/// timeline is recorded. A marker with a default, so macro-generated code names a protocol rather
/// than an enum case from a module the use site may not import.
public protocol FullMutationCapture: MutationCapturing {}

public extension FullMutationCapture {
    var mutationCapture: MutationCapture {
        .full
    }
}

/// The `@TracedForwarder` conformance: the generated setter records writes that cross the wrapper,
/// and nothing records the wrapped object's internal writes — boundary capture.
public protocol BoundaryMutationCapture: MutationCapturing {}

public extension BoundaryMutationCapture {
    var mutationCapture: MutationCapture {
        .boundary
    }
}
