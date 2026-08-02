import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

// A typed, result-builder API for describing *how to interrogate* a system under test — the one thing a
// developer authors. The SUT stays oracle-agnostic (plain notifications / KVO + optional deliberate
// markers); the Scenario, and only the Scenario, knows the oracle. Machinery (recorder, interceptor,
// context, replay, diff) is hidden behind `scenario.verify(against:)`.
//
// Prototype: proves the ergonomics on a decoupled checkout, with call-ordering variation as the headline
// (stateful/model-based differential testing — the baseline branch *is* the model).

/// Handed to the system factory and seam reads: the `NotificationCenter` to inject (so observation works
/// with zero SUT coupling) and typed seam readings backed by the replay cassette.
public struct SeamContext {
    public let notifications: NotificationCenter
    let cassette: Cassette

    public func int(_ seam: String, default value: Int64) -> Int64 {
        cassette.int(seam: seam, live: { value })
    }

    public func double(_ seam: String, default value: Double) -> Double {
        cassette.double(seam: seam, live: { value })
    }
}

/// A labeled, typed operation on the system under test, plus ordering constraints. `$0` is the system.
public struct Op<S> {
    public let label: String
    let action: (S, SeamContext) -> Void
    var mustBeLast = false
    var afters: [String] = []

    /// A simple op.
    public init(_ label: String, _ action: @escaping (S) -> Void) {
        self.label = label
        self.action = { system, _ in action(system) }
    }

    /// A *parameterized* op: reads generated values from the seam context, so arguments become
    /// property-varied surface (e.g. `qty: Int(seams.int("coffeeQty", default: 10))`).
    public init(_ label: String, _ action: @escaping (S, SeamContext) -> Void) {
        self.label = label
        self.action = action
    }

    /// This op must run last (e.g. `checkout`).
    public func last() -> Op<S> {
        var copy = self; copy.mustBeLast = true; return copy
    }

    /// This op may only run after `label` (a partial-order edge).
    public func after(_ label: String) -> Op<S> {
        var copy = self; copy.afters.append(label); return copy
    }
}

/// A declared variation of the input surface: seam values, and/or call ordering.
public enum Variation {
    case seam(String, SeamDomain)
    case ordering(max: Int)
}

/// Vary a seam over a domain (property-based breadth). Composes with `Ordering`.
public func Seam(_ name: String, _ domain: SeamDomain) -> Variation {
    .seam(name, domain)
}

/// Explore valid call orderings (linear extensions of the declared partial order).
public func Ordering(max: Int = 100) -> Variation {
    .ordering(max: max)
}

@resultBuilder public enum OperationsBuilder<S> {
    public static func buildExpression(_ operation: Op<S>) -> Op<S> {
        operation
    }

    public static func buildBlock(_ ops: Op<S>...) -> [Op<S>] {
        ops
    }
}

@resultBuilder public enum VariationsBuilder {
    public static func buildBlock(_ variations: Variation...) -> [Variation] {
        variations
    }
}

/// The scenario. Built fluently; the nested `operations`/`vary` use result-builders so the call site
/// reads declaratively without losing Swift's type-checking, autocomplete, or rename-safety.
public struct Scenario<S> {
    public let name: String
    var makeSystem: (SeamContext) -> S = { _ in fatalError("Scenario.system(_:) was not set") }
    var operations: [Op<S>] = []
    /// Which notification names to capture. `nil` (the default) captures *everything* — a behavioral
    /// oracle watches all behavior by default. A non-nil set is an explicit allowlist override set via
    /// `.observe(notifications:)`, for callers who want to narrow to a few product channels.
    var notificationNames: Set<String>?
    var observationCenter: NotificationCenter?
    var tolerances: ToleranceSpec = .strict
    var intent: IntentSpec = .none
    var seamDomains: [String: SeamDomain] = [:]
    /// The builds to verify against this scenario's baseline, declared via `.candidates { }`.
    var candidates: [Candidate<S>] = []
    var exploreOrdering = false
    var maxOrderings = 100

    public init(_ name: String) {
        self.name = name
    }

    /// How to construct the system under test. Seams are injected here — including the observation
    /// `NotificationCenter` (`SeamContext.notifications`) and any recording collaborator doubles a
    /// legacy singleton was made injectable to accept. A boundary the SUT reaches without a declared,
    /// injected seam is unobserved by construction (there is no runtime interception to fall back on).
    public func system(_ make: @escaping (SeamContext) -> S) -> Scenario<S> {
        var copy = self; copy.makeSystem = make; return copy
    }

    /// The interactions to drive, as labeled ops with optional ordering constraints.
    public func operations(@OperationsBuilder<S> _ build: () -> [Op<S>]) -> Scenario<S> {
        var copy = self; copy.operations = build(); return copy
    }

    /// Narrow observation to an explicit allowlist of notification names. **Optional** — scenarios
    /// capture *all* notifications by default (a behavioral oracle watches everything), so this is an
    /// opt-in narrowing for callers who genuinely want to ignore every channel except the ones listed.
    /// To silence a specific noisy channel while keeping the rest, prefer `.ignore(notifications:)`.
    public func observe(notifications: [String]) -> Scenario<S> {
        var copy = self; copy.notificationNames = Set(notifications); return copy
    }

    /// Opt a noisy notification channel *out* of the diff while still capturing everything else. The
    /// raw trace stays faithful (reports show every post); the named channels are dropped from both
    /// sides at diff time, so a channel whose count varies run-to-run stops causing spurious
    /// divergences. Symmetric with `.observe(notifications:)`; writes into the tolerance spec.
    public func ignore(notifications names: [String]) -> Scenario<S> {
        var copy = self
        copy.tolerances.ignoredNotificationNames += names
        return copy
    }

    /// Observe an explicit NotificationCenter (e.g. `.default`) instead of the default isolated one — so
    /// a SUT that posts to a center you don't control can still be watched with no code change. Notifications
    /// are an already-decoupled broadcast, so this needs no seam. **Isolation is the caller's job:** the
    /// default (a fresh per-window `NotificationCenter()` handed through `SeamContext.notifications`) is
    /// inherently isolated; pointing this at a process-wide center under a *parallel* test runner can let a
    /// sibling capture's posts leak in (prefer injecting the context center, or serialize the suite).
    public func observing(on center: NotificationCenter) -> Scenario<S> {
        var copy = self; copy.observationCenter = center; return copy
    }

    /// Declared acceptable deltas.
    public func tolerate(_ spec: ToleranceSpec) -> Scenario<S> {
        var copy = self; copy.tolerances = spec; return copy
    }

    /// Extension mode: declare the deltas the change was *meant* to make. Declared divergences are
    /// reported as `intended` and don't gate; the verdict gates on the residual collateral. The default
    /// (`IntentSpec.none`) is parity mode — every divergence gates. See `IntentSpec`.
    public func intend(_ spec: IntentSpec) -> Scenario<S> {
        var copy = self; copy.intent = spec; return copy
    }

    /// What to vary — seam domains and/or call ordering.
    public func vary(@VariationsBuilder _ build: () -> [Variation]) -> Scenario<S> {
        var copy = self
        for variation in build() {
            switch variation {
            case let .seam(name, domain): copy.seamDomains[name] = domain
            case let .ordering(max): copy.exploreOrdering = true; copy.maxOrderings = max
            }
        }
        return copy
    }
}
