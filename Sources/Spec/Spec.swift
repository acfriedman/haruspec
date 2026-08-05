import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

// A typed, result-builder API for describing *how to interrogate* a system under test — the one thing a
// developer authors. The SUT stays oracle-agnostic (plain notifications / KVO + optional deliberate
// markers); the Spec, and only the Spec, knows the oracle. Machinery (recorder, interceptor,
// context, replay, diff) is hidden behind `spec.verify(against:)`.
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

    /// The categorical read, paired with `.oneOf(…)`: an input whose interesting values are named
    /// rather than ranged reads as itself, instead of an int the op has to decode.
    public func string(_ seam: String, default value: String) -> String {
        cassette.string(seam: seam, live: { value }) ?? value
    }
}

/// A labeled, typed operation on the system under test, plus ordering constraints. `$0` is the system.
public struct Op<S> {
    public let label: String
    let action: (S, SeamContext) -> Void
    var mustBeLast = false
    /// Soft preconditions: labels this op is *expected* to follow, declared with `.after(_:)`.
    /// Exploration deliberately breaks them in part of its sample rather than filtering them out.
    var afters: [String] = []
    /// Hard ordering gates: labels that must have run before this op, declared with `.requires(_:)`.
    /// Enforced while an ordering is built, so no sampled ordering ever violates one. The in-order
    /// stratum folds `afters` in here temporarily (see `gated`); the declared arrays stay untouched.
    var gates: [String] = []
    /// How many times ordering exploration may apply this op, declared with `.repeating(_:)`. `nil`
    /// defers to the spec-wide `Ordering(repeating:)`. A *range* means the count itself varies between
    /// sequences, which is the only way a shorter run — a checkout on an empty cart — is reachable.
    var multiplicity: ClosedRange<Int>?
    /// Domains declared on this op by `Op(_:varying:)`, against the seam keys they synthesized.
    /// `Spec.operations(_:)` merges them into the declared surface, so a typed argument is
    /// property-varied without anyone naming it in `.vary` — which is the join that used to be a string.
    var argumentDomains: [(seam: String, domain: SeamDomain)] = []

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

    /// This op must run last (e.g. `checkout`). Implies `.once()`.
    public func last() -> Op<S> {
        var copy = self; copy.mustBeLast = true; return copy.repeating(1)
    }

    /// Exempt this op from ordering repetition — it runs exactly once per sequence. For an op whose
    /// second application is meaningless or destructive rather than interesting.
    public func once() -> Op<S> {
        repeating(1)
    }

    /// Apply this op exactly `count` times in every sequence, overriding `Ordering(repeating:)`.
    ///
    /// The spec-wide number is one dial for every op, which stops fitting as soon as ops are collapsed:
    /// one `add` wants applying six times where one `applyPromo` wants two, and raising the global
    /// number buys both. Sequence length is the cost model's one super-linear term, so buying length
    /// you don't want is the expensive mistake.
    public func repeating(_ count: Int) -> Op<S> {
        repeating(count ... count)
    }

    /// Apply this op *between* `range.lowerBound` and `range.upperBound` times — the count varies from
    /// sequence to sequence rather than being fixed.
    ///
    /// Exact multiplicity means every sequence runs every op the same number of times, so states that
    /// need an op to be *absent* or *scarce* — checkout on an empty cart, a single-line cart, a run
    /// where the promo never fired — are unreachable no matter how many orderings are sampled. A range
    /// is what reaches them, and the sequences it adds are shorter, so they are also cheaper than the
    /// ones already being run.
    public func repeating(_ range: ClosedRange<Int>) -> Op<S> {
        precondition(range.lowerBound >= 0, "an op cannot appear a negative number of times")
        precondition(range.upperBound >= 1, "an op declared 0 ... 0 would never run — delete it instead")
        var copy = self
        copy.multiplicity = range
        return copy
    }

    /// This op is *expected* to run after `label` — a soft precondition, not a filter.
    ///
    /// Exploration spends most of its ordering budget on sequences that respect the declaration and a
    /// deliberate slice on sequences that break it, tagging the latter in the verdict. A differential
    /// oracle has no expected value to contradict: `removeSku("MUG")` on an empty cart is simply
    /// another input both branches must agree on, and code that isn't defensive about it is the
    /// finding. Filtering those orderings out is how a false negative hides.
    ///
    /// Use `.requires(_:)` for the rare op that *traps* out of order.
    public func after(_ label: String) -> Op<S> {
        var copy = self; copy.afters.append(label); return copy
    }

    /// This op may not run before `label` — a hard gate no sampled ordering will ever violate.
    ///
    /// For the op that would *trap* out of order (a force-unwrap on legacy state), where a violation
    /// aborts the process and costs the whole run its verdict rather than producing a finding. Prefer
    /// `.after(_:)`: it says the same thing about intent while leaving the defensive path reachable.
    public func requires(_ label: String) -> Op<S> {
        var copy = self; copy.gates.append(label); return copy
    }
}

/// A declared variation of the input surface: seam values, call ordering, and/or how much of it to buy.
public enum Variation {
    case seam(String, SeamDomain)
    case ordering(max: Int, repeating: Int)
    case budget(runs: Int)
}

/// Vary a seam over a domain (property-based breadth). Composes with `Ordering`.
public func Seam(_ name: String, _ domain: SeamDomain) -> Variation {
    .seam(name, domain)
}

/// Explore valid call orderings (linear extensions of the declared partial order).
///
/// `repeating` is how many times an op may appear in one ordering — 2 by default, because applying
/// an operation twice is where a surprising amount of legacy behavior lives (merge-into-existing
/// rather than append; remove-what-is-not-there). Pass `1` to explore permutations only, or exempt
/// a single op with `.once()`.
public func Ordering(max: Int = 100, repeating: Int = 2) -> Variation {
    precondition(repeating >= 1, "an op has to appear at least once")
    return .ordering(max: max, repeating: repeating)
}

/// How many differential runs this spec may spend, in total, across *both* axes — the one number that
/// bounds its cost. Each run drives the baseline and the candidate once over one (ordering, seam
/// cassette) pair, so cost is roughly `runs × 2 ×` whatever one pass through the ops costs.
///
/// Orderings are bought first (up to `Ordering(max:)`) and the remainder becomes seam breadth: a second
/// call ordering reaches code that a second value for the same seam cannot. Undeclared, the axes take
/// their own sizes — `Ordering(max:)` orderings × 64 seam variants — which is the historical default and
/// is why a defaulted spec is 6,400 runs.
public func Budget(runs: Int) -> Variation {
    precondition(runs >= 1, "a budget has to buy at least one run")
    return .budget(runs: runs)
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

/// The spec. Built fluently; the nested `operations`/`vary` use result-builders so the call site
/// reads declaratively without losing Swift's type-checking, autocomplete, or rename-safety.
public struct Spec<S> {
    public let name: String
    var makeSystem: (SeamContext) -> S = { _ in fatalError("Spec.system(_:) was not set") }
    var operations: [Op<S>] = []
    /// Which notification names to capture. `nil` (the default) captures *everything* — a behavioral
    /// oracle watches all behavior by default. A non-nil set is an explicit allowlist override set via
    /// `.observe(notifications:)`, for callers who want to narrow to a few product channels.
    var notificationNames: Set<String>?
    var observationCenter: NotificationCenter?
    var tolerances: Tolerance = .strict
    var intent: Intent = .none
    var seamDomains: [String: SeamDomain] = [:]
    /// Which of `seamDomains` came from a typed op argument — so a `Seam(_:_:)` that collides with one
    /// traps instead of quietly redefining an argument's domain from a distance.
    var argumentSeams: Set<String> = []
    /// The builds a catalog can enumerate, declared via `.candidates { }`. Empty for a spec whose
    /// suite checks each build inline (`check(_:expecting:_:)`), which is the ordinary case.
    var candidates: [Candidate<S>] = []
    var exploreOrdering = false
    var maxOrderings = 100
    var orderingRepeats = 2
    /// Total differential runs this spec may spend, declared via `Budget(runs:)`. `nil` lets each axis
    /// take its own size (`maxOrderings` × `SpecDefaults.variantCount`).
    var explorationBudget: Int?

    public init(_ name: String) {
        self.name = name
    }

    /// How to construct the system under test. Seams are injected here — including the observation
    /// `NotificationCenter` (`SeamContext.notifications`) and any recording collaborator doubles a
    /// legacy singleton was made injectable to accept. A boundary the SUT reaches without a declared,
    /// injected seam is unobserved by construction (there is no runtime interception to fall back on).
    public func system(_ make: @escaping (SeamContext) -> S) -> Spec<S> {
        var copy = self; copy.makeSystem = make; return copy
    }

    /// The interactions to drive, as labeled ops with optional ordering constraints.
    ///
    /// Typed op arguments declare their domains here rather than in `.vary`, so this is where they join
    /// the declared surface. Order between `.operations` and `.vary` doesn't matter — both write the
    /// same dictionary, and a collision between the two traps rather than letting one silently win.
    public func operations(@OperationsBuilder<S> _ build: () -> [Op<S>]) -> Spec<S> {
        var copy = self
        copy.operations = build()
        for operation in copy.operations {
            for argument in operation.argumentDomains {
                precondition(
                    copy.seamDomains[argument.seam] == nil,
                    "\"\(argument.seam)\" is declared twice — a typed argument's key is "
                        + "`<op>.<name-or-position>`, so rename the argument or the Seam it collides with"
                )
                copy.seamDomains[argument.seam] = argument.domain
                copy.argumentSeams.insert(argument.seam)
            }
        }
        return copy
    }

    /// Narrow observation to an explicit allowlist of notification names. **Optional** — specs
    /// capture *all* notifications by default (a behavioral oracle watches everything), so this is an
    /// opt-in narrowing for callers who genuinely want to ignore every channel except the ones listed.
    /// To silence a specific noisy channel while keeping the rest, prefer `.ignore(notifications:)`.
    public func observe(notifications: [String]) -> Spec<S> {
        var copy = self; copy.notificationNames = Set(notifications); return copy
    }

    /// Opt a noisy notification channel *out* of the diff while still capturing everything else. The
    /// raw trace stays faithful (reports show every post); the named channels are dropped from both
    /// sides at diff time, so a channel whose count varies run-to-run stops causing spurious
    /// divergences. Symmetric with `.observe(notifications:)`; writes into the tolerance spec.
    public func ignore(notifications names: [String]) -> Spec<S> {
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
    public func observing(on center: NotificationCenter) -> Spec<S> {
        var copy = self; copy.observationCenter = center; return copy
    }

    /// Declared acceptable deltas.
    public func tolerate(_ spec: Tolerance) -> Spec<S> {
        var copy = self; copy.tolerances = spec; return copy
    }

    /// Extension mode: declare the deltas the change was *meant* to make. Declared divergences are
    /// reported as `intended` and don't gate; the verdict gates on the residual collateral. The default
    /// (`Intent.none`) is parity mode — every divergence gates. See `Intent`.
    public func intend(_ spec: Intent) -> Spec<S> {
        var copy = self; copy.intent = spec; return copy
    }

    /// What to vary — seam domains and/or call ordering.
    public func vary(@VariationsBuilder _ build: () -> [Variation]) -> Spec<S> {
        var copy = self
        for variation in build() {
            switch variation {
            case let .seam(name, domain):
                precondition(
                    !copy.argumentSeams.contains(name),
                    "\(name) is already a typed argument's domain — declaring it again here would "
                        + "redefine it from a distance, which is the join the typed form removes"
                )
                copy.seamDomains[name] = domain
            case let .ordering(max, repeating):
                copy.exploreOrdering = true
                copy.maxOrderings = max
                copy.orderingRepeats = repeating
            case let .budget(runs): copy.explorationBudget = runs
            }
        }
        return copy
    }
}
