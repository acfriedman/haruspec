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

/// A generated recording double's construction contract (`@Haruspec` emits the conformance on its
/// `Double<Protocol>`): built from the capture's context, so its synthesized returns read generated
/// seam values and `SeamContext.double(_:)` can construct-and-register in one move.
public protocol SeamDouble: TraceLabeled {
    init(_ seams: SeamContext)
    /// The collaborator boundaries this double serves — the stamped protocol and the protocols it
    /// refines, emitted from the inheritance clause. ``SeamContext/resolve(_:)`` matches these by type
    /// identity, so the pasted refinement *is* the registry entry.
    static var servedBoundaries: [Any.Type] { get }
}

/// A generated forwarder's registry entry (`@Haruspec` emits the conformance on its
/// `Traced<Protocol>`): which boundary it forwards, and how to wrap a conformer of it. This is how a
/// spec over `any Cart` records through `TracedCart` without naming it.
public protocol StampedForwarder: AnyObject {
    /// The existential the forwarder wraps, `(any Cart).self`.
    static var forwardedBoundary: Any.Type { get }
    /// Wraps a conformer in the forwarder, so the one wrap serves a build however it was made.
    ///
    /// - Parameter conformer: The build to wrap, possibly already wrapped.
    /// - Returns: A forwarder around `conformer`, `conformer` itself when it is already one, or `nil`
    ///   when it does not conform to the boundary.
    static func wrap(_ conformer: Any) -> Any?
}

public extension SeamDouble {
    /// A hand-written double serves nothing declaratively; it is still constructible explicitly.
    static var servedBoundaries: [Any.Type] {
        []
    }
}

/// Handed to the system factory and seam reads: the `NotificationCenter` to inject (so observation works
/// with zero SUT coupling) and typed seam readings backed by the replay cassette.
public struct SeamContext {
    public let notifications: NotificationCenter
    let cassette: Cassette
    /// Per-type factories for synthesized custom-type returns, declared via `Spec.generates(_:_:)`
    /// and consulted by generated doubles (`value(_:key:)` below). Keyed by the returned type.
    var makers: [ObjectIdentifier: (SeamContext, String) -> Any] = [:]
    /// Capture-scoped resources, declared via `Spec.provides(_:_:)` and consulted by `resolve(_:)`
    /// for a constructor parameter no double serves — an isolated store, a scratch directory. Built
    /// fresh each capture, like `notifications` (the built-in resource this generalizes).
    var resourceMakers: [ObjectIdentifier: (SeamContext) -> Any] = [:]
    /// The work this capture's scheduling doubles were handed, held until the engine drains it. A
    /// stamped scheduling protocol's double (`@Haruspec(schedules:)`) enqueues here; the capture runs
    /// it after the ops, and a derived op waiting on a completion block runs it meanwhile.
    public let backlog = WorkBacklog()

    /// Hands a recording double to the subject as an injected collaborator. The act of injection is
    /// the declaration: the double states its own trace label (`TraceLabeled`, emitted on every
    /// stamped forwarder and double), and that label leaves the completeness audit's denominator — the
    /// interaction is captured at this boundary, so the double's sources are the fixture's, not the
    /// subject's. A traced collaborator constructed *around* this call is not registered, and its
    /// sources gate: over-reporting stays the safe direction.
    public func inject<D: TraceLabeled>(_ double: D) -> D {
        TraceOrigins.collector?.noteInjected(label: double.traceLabel)
        return double
    }

    /// Constructs a generated recording double (a stamp's `Double<Protocol>`) and hands it in, in one move — the
    /// double reads its synthesized returns through this context, and constructing it here is what
    /// registers it as an injected collaborator.
    public func double<D: SeamDouble>(_ type: D.Type) -> D {
        inject(type.init(self))
    }

    public func int(_ seam: String, default value: Int64) -> Int64 {
        cassette.int(seam: seam, live: { value })
    }

    public func double(_ seam: String, default value: Double) -> Double {
        cassette.double(seam: seam, live: { value })
    }

    public func bool(_ seam: String, default value: Bool) -> Bool {
        cassette.bool(seam: seam, live: { value })
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
    // Async, so an operation may drive an `actor` or any other `async` surface. A synchronous
    // closure converts to this implicitly — Swift treats sync functions as a subtype of async ones —
    // so every existing sync `Op { … }` declaration keeps working untouched.
    let action: (S, SeamContext) async -> Void
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
    /// property-varied without anyone naming it in `.vary` — the string join the typed form removes.
    var argumentDomains: [(seam: String, domain: SeamDomain)] = []
    /// Field domains a `.generated(_:)` argument contributes, under the model's type-scoped keys.
    /// Merged fill-if-vacant: the fields are shared surface, and an explicit `Seam` narrows them.
    var generatedArgumentFields: [(seam: String, domain: SeamDomain)] = []
    /// Factories a `.generated(_:)` argument carries, registered so the read can build the model.
    var argumentMakers: [(type: ObjectIdentifier, make: (SeamContext, String) -> Any)] = []

    /// A simple op.
    public init(_ label: String, _ action: @escaping (S) async -> Void) {
        self.label = label
        self.action = { system, _ in await action(system) }
    }

    /// A *parameterized* op: reads generated values from the seam context, so arguments become
    /// property-varied surface (e.g. `qty: Int(seams.int("coffeeQty", default: 10))`).
    public init(_ label: String, _ action: @escaping (S, SeamContext) async -> Void) {
        self.label = label
        self.action = action
    }

    /// Requires this op to run last (e.g. `checkout`). Implies `.once()`.
    public func last() -> Op<S> {
        var copy = self; copy.mustBeLast = true; return copy.repeating(1)
    }

    /// Exempts this op from ordering repetition — it runs exactly once per sequence. For an op whose
    /// second application is meaningless or destructive rather than interesting.
    public func once() -> Op<S> {
        repeating(1)
    }

    /// Applies this op exactly `count` times in every sequence, overriding `Ordering(repeating:)`.
    ///
    /// The spec-wide number is one dial for every op, which stops fitting as soon as ops are collapsed:
    /// one `add` wants applying six times where one `applyPromo` wants two, and raising the global
    /// number buys both. Sequence length is the cost model's one super-linear term, so buying length
    /// you don't want is the expensive mistake.
    public func repeating(_ count: Int) -> Op<S> {
        repeating(count ... count)
    }

    /// Applies this op *between* `range.lowerBound` and `range.upperBound` times — the count varies from
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

    /// Declares this op *expected* to run after `label` — a soft precondition, not a filter.
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

    /// Forbids this op from running before `label` — a hard gate no sampled ordering will ever violate.
    ///
    /// For the op that would *trap* out of order (a force-unwrap on legacy state), where a violation
    /// aborts the process and costs the whole run its verdict rather than producing a finding. Prefer
    /// `.after(_:)`: it says the same thing about intent while leaving the defensive path reachable.
    public func requires(_ label: String) -> Op<S> {
        var copy = self; copy.gates.append(label); return copy
    }
}

/// One observed property of the boundary: the fully qualified label its writes carry
/// (`"Cart.itemCount"` — matching what the stamped forwarder records), and how the harness
/// reads its value back for the end-state snapshot. Declared via `.observes(_:)`, or derived from
/// the boundary protocol's `var` requirements by `@Haruspec`.
public struct Observed<S> {
    let label: String
    /// Async so an actor port's isolated property can witness a `{ get async }` requirement and
    /// still be read back. A synchronous closure converts implicitly, like `Op.action`.
    let read: (S) async -> Any

    public init(_ label: String, _ read: @escaping (S) async -> Any) {
        self.label = label
        self.read = read
    }
}

/// A declared variation of the input surface: seam values, call ordering, and/or how much of it to buy.
public enum Variation {
    case seam(String, SeamDomain)
    case ordering(max: Int, repeating: Int)
    case budget(runs: Int)
}

/// Varies a seam over a domain (property-based breadth). Composes with `Ordering`.
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
/// their own sizes — `Ordering(max:)` orderings × 64 seam variants — which is why a defaulted spec is
/// 6,400 runs.
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
    var makeSystem: (SeamContext) -> S = { _ in
        fatalError(
            "this spec has no system factory — author it (.system { context in … }), or let the "
                + "derivation supply it: paste the baseline's init into the @Haruspec protocol and "
                + "its catalog emits the wiring (collaborators resolve to their stamped doubles, "
                + "NotificationCenter to the capture's)"
        )
    }

    /// Constructs a conformer through the boundary's pasted `init` and wraps it — set by
    /// `.operations(derivedFrom:)` when the catalog derives construction, and what
    /// `check(_ conformer:)` runs. `nil` when construction has to be authored.
    var makeConformer: ((SeamContext, Any.Type) -> S)?
    /// Wraps every build in the capture boundary before it is driven — the stamped protocol's
    /// forwarder, so the baseline and a port authored by closure record through the same class.
    /// Set from a derived catalog; `nil` finds the forwarder by census at the first capture, and is
    /// identity when `S` is not a stamped protocol.
    var wrapCandidate: ((S) -> S)?

    var operations: [Op<S>] = []
    var tolerances: Tolerance = .strict
    var seamDomains: [String: SeamDomain] = [:]
    /// What the golden template reads at each declared seam: the domain's first interior value, so the
    /// recording sits inside the declared surface (a cart with items in it) rather than at the op's
    /// fallback default — the degenerate edge every other variant would then be measured against.
    var goldenReadings: [String: CanonicalValue] {
        seamDomains.compactMapValues(\.interiorValues.first)
    }

    /// Which of `seamDomains` came from a typed op argument — so a `Seam(_:_:)` that collides with one
    /// traps instead of quietly redefining an argument's domain from a distance.
    var argumentSeams: Set<String> = []
    /// The builds a catalog can enumerate, declared via `.candidates { }`. Empty for a spec whose
    /// suite checks each build inline (`check(_:expecting:_:)`), which is the ordinary case.
    var candidates: [Candidate<S>] = []
    /// Channels the spec accepts as uncaptured for every candidate, via `.accepts(uncaptured:)` —
    /// merged into each verification's intent where the audit resolves declarations.
    var acceptedBlindSpots: [String] = []
    /// Custom-type factories for synthesized double returns, via `.generates(_:_:)` — threaded into
    /// every capture's `SeamContext`.
    var valueMakers: [ObjectIdentifier: (SeamContext, String) -> Any] = [:]
    /// Capture-scoped resource factories, via `.provides(_:_:)` — threaded the same way.
    var specResourceMakers: [ObjectIdentifier: (SeamContext) -> Any] = [:]
    var exploreOrdering = false
    var maxOrderings = 100
    var orderingRepeats = 2
    /// Total differential runs this spec may spend, declared via `Budget(runs:)`. `nil` lets each axis
    /// take its own size (`maxOrderings` × `SpecDefaults.variantCount`).
    var explorationBudget: Int?
    /// Op-scoped keys whose domains the engine supplied rather than the author — set by
    /// `.operations(derivedFrom:)`, rendered on every verdict so a green from a defaulted surface
    /// says so.
    var derivedDefaultSeams: Set<String> = []
    /// The boundary properties this spec observes (see `Observed`): each one is snapshot at the end
    /// of every capture — the state contract, which gates always.
    var observedProperties: [Observed<S>] = []

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
        adopting(build())
    }

    /// The one merge for an op list, authored or derived: fold each op's declared argument domains,
    /// generated-model fields, and factories into the spec, with the collision rules that keep a key
    /// from being defined twice.
    func adopting(_ ops: [Op<S>]) -> Spec<S> {
        var copy = self
        copy.operations = ops
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
            // Generated-model fields are shared, type-scoped surface: two ops taking a Product read
            // the same tracks on purpose, and an explicit `Seam` on a field key narrows it — so these
            // fill vacancies rather than trapping, exactly like a `.generates` adoption.
            for field in operation.generatedArgumentFields where copy.seamDomains[field.seam] == nil {
                copy.seamDomains[field.seam] = field.domain
            }
            for maker in operation.argumentMakers {
                copy.valueMakers[maker.type] = maker.make
            }
        }
        return copy
    }

    /// Opt a noisy notification channel *out* of the diff while still capturing everything else. The
    /// raw trace stays faithful (reports show every post); the named channels are dropped from both
    /// sides at diff time, so a channel whose count varies run-to-run stops causing spurious
    /// divergences. The only notification knob a spec has, and it is subtractive by design: an
    /// allowlist would hide a channel the subject *starts* posting, which is the failure a behavioral
    /// oracle exists to catch. Writes into the tolerance spec, so the raw trace stays complete.
    public func ignore(notifications names: [String]) -> Spec<S> {
        var copy = self
        copy.tolerances.ignoredNotificationNames += names
        return copy
    }

    // Observe an explicit NotificationCenter (e.g. `.default`) instead of the default isolated one — so
    // a SUT that posts to a center you don't control can still be watched with no code change. Notifications
    // are an already-decoupled broadcast, so this needs no seam. **Isolation is the caller's job:** the
    // default (a fresh per-window `NotificationCenter()` handed through `SeamContext.notifications`) is
    // inherently isolated; pointing this at a process-wide center under a *parallel* test runner can let a
    // sibling capture's posts leak in (prefer injecting the context center, or serialize the suite).

    /// Returns a copy of the spec whose captures are diffed under `spec` instead of strict parity.
    ///
    /// - Parameter spec: The deltas the diff accepts.
    /// - Returns: The spec with `spec` as its whole tolerance, any earlier one replaced; the receiver
    ///   is unchanged.
    public func tolerate(_ spec: Tolerance) -> Spec<S> {
        var copy = self; copy.tolerances = spec; return copy
    }

    /// Observes boundary properties: snapshots each at the end of every capture, and the end-state
    /// values gate unconditionally. The label is the fully qualified one the forwarder records
    /// (`"Cart.itemCount"`). Derived specs get this from the protocol's `var` requirements; this is
    /// the authored spelling.
    public func observes(_ properties: Observed<S>...) -> Spec<S> {
        var copy = self
        copy.observedProperties += properties
        return copy
    }

    /// Accepts that the *subject* reaches an effect channel the capture cannot see — the spec-level
    /// home of `Accepts(uncaptured:)`, for a blind spot every candidate shares because it lives in
    /// the baseline's own sources (a legacy singleton fanning out through the global center).
    ///
    /// Spec-level deliberately, where port intent deliberately is not: an intent declared on the spec
    /// would leak one port's excuses to every candidate, but an uncaptured channel in covered baseline
    /// code IS every candidate's shared context — the same reasoning that puts `Tolerance` here. A
    /// channel only one port introduces still belongs at its check site, via `Intent`.
    public func accepts(uncaptured channels: String...) -> Spec<S> {
        var copy = self
        copy.acceptedBlindSpots += channels
        return copy
    }

    /// How to build a `T` when a synthesized double must return one (a stamped double's custom-type
    /// requirement). One declaration per type, on the spec — both sides of every differential build
    /// their values through the same factory.
    ///
    /// `key` is the synthesized seam key (`"<label>.<method>"`); **read every varying field through
    /// `seams`, namespaced under it** — `seams.int("\(key).cents", default: 0)` — so the value is
    /// recorded like any other seam, sweeps when a spec declares a domain for that field's key, and
    /// replays identically. A factory that invents values outside the seams (a `Date()`, a random)
    /// breaks replay determinism the same way any unseamed read does.
    public func generates<T>(_ type: T.Type, _ make: @escaping (SeamContext, String) -> T) -> Spec<S> {
        var copy = self
        copy.valueMakers[ObjectIdentifier(type)] = { make($0, $1) }
        return copy
    }

    /// Provide a capture-scoped resource: how to build a `T` when a derived system's constructor
    /// parameter wants one and no stamped double serves it — an isolated in-memory store, a scratch
    /// directory. The maker runs once per capture, so every probe gets a fresh, isolated instance:
    /// this is `notifications` (the built-in resource) generalized to types the engine cannot know.
    ///
    /// A resource is infrastructure the subject runs *on*, not a boundary the diff observes — nothing
    /// is recorded at it. State it holds becomes comparable through the subject's own read surface,
    /// so a spec that provides a store should also drive the ops that read it back.
    public func provides<T>(_ type: T.Type, _ make: @escaping (SeamContext) -> T) -> Spec<S> {
        var copy = self
        copy.specResourceMakers[ObjectIdentifier(type)] = { make($0) }
        return copy
    }

    /// Adopts a model's own generator (`SeamGenerated`) — the reusable form, one line per spec. The
    /// type's field domains are discovered here, at declaration time, by a dry run of the factory,
    /// so they join the declared surface exactly like `.vary` seams: swept by the variant budget,
    /// scheduled for boundary edges, reported in `seamPositions` — and known to a replay, whose
    /// schedule recomputes from this same spec value.
    ///
    /// A field key already declared explicitly (a `Seam("Membership.tier", …)` in `.vary`, before or
    /// after this call) keeps its explicit domain: the model states how it *can* mutate, the spec may
    /// narrow how it *does* here.
    public func generates<T: SeamGenerated>(_ type: T.Type) -> Spec<S> where T.Generated == T {
        var copy = self
        copy.valueMakers[ObjectIdentifier(type)] = { context, _ in
            T.generated(from: FieldSeams(mode: .live(context), prefix: "\(T.self)"))
        }
        let discovery = DomainCollector()
        _ = T.generated(from: FieldSeams(mode: .discovery(discovery), prefix: "\(T.self)"))
        for (key, domain) in discovery.domains where copy.seamDomains[key] == nil && !copy.argumentSeams.contains(key) {
            copy.seamDomains[key] = domain
        }
        return copy
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
