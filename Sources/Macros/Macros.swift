// Opt-in, zero-code method capture. Import alongside `HaruspecTrace`:
//
//     import HaruspecTrace
//     import HaruspecMacros
//
//     @Traced final class CartService { ... }   // every method now records call/args/return
//
// The generated bodies record to the ambient `TraceContext.current`, so instrumented types need no
// recorder property and are inert outside a capture window.

import HaruspecTrace

/// Instruments every instance method of a class (or actor) with entry/exit trace capture.
///
/// Pass a stable label to decouple the trace from the concrete type name — useful when the same
/// logical type is captured before/after a rename, or across variants:
///
///     @Traced("CartService") final class CartServiceV2 { ... }
///
/// With no argument the type's own name is used. Pass `timing: true` to also record a signpost
/// interval for *every* method; for per-method timing use `@Timed` instead.
///
/// **Safe on code that ships.** The instrumentation is emitted inside `#if DEBUG`; a release build
/// keeps each method's own statements verbatim — no shim, no recorder lookup, nothing to strip. So
/// the attribute goes on the real type rather than a DEBUG-only copy of it, and a migration
/// candidate stays one unconditional class. (The module is still linked in release; only the
/// generated behavior is gated.)
/// Also emits a `TraceLabeled` conformance, so an instrumented instance can state the label its
/// events carry — which is what `SeamContext.inject` reads to register a collaborator boundary
/// without the label being typed a second time.
///
/// Stored `var` properties are instrumented too (`@TracedProperty` — a `didSet` recording each
/// committed write as a `stateChange`), and the type conforms to `FullMutationCapture` to say so:
/// the whole write timeline is on the trace, which is what lets the mutation-order diff compare it.
/// Computed and observed properties are skipped — an accessor macro cannot add observers where
/// accessors already exist — so a type whose observable state is all passthrough contributes writes
/// only where they actually commit.
@attached(memberAttribute)
@attached(extension, conformances: TraceLabeled, FullMutationCapture, names: named(traceLabel))
public macro Traced(_ typeLabel: String? = nil, timing: Bool = false) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "TracedMacro")

/// Generates a recording test double from a pasted protocol — the collaborator counterpart of
/// `@TracedForwarder`, with nothing behind the boundary.
///
///     @TracedDouble(label: "Inventory")
///     protocol InventoryDouble: InventoryReserving {
///         func reserve(sku: String, quantity: Int)
///         func stock(sku: String) -> Int
///     }
///     // → final class TracedInventoryDouble: records "Inventory.reserve" and no-ops;
///     //   stock(sku:) returns the seam "Inventory.stock" (default 0)
///
/// Construct one through the capture context — `context.double(TracedInventoryDouble.self)` — which
/// also registers it as an injected collaborator. `Void` requirements record the call and do nothing:
/// the interaction at the boundary is the behavior a differential checks, and everything past it is
/// fixture. A value-returning requirement reads the seam `"<label>.<method>"` — the type's zero by
/// default, swept when a spec declares a domain for that key in `.vary`, recorded and replayed like
/// any other seam. Collections return their genuine empty, and an optional custom type returns `nil`.
///
/// A *required* custom type has no universal zero, so the spec declares its factory once:
///
///     .generates(Receipt.self) { seams, key in
///         Receipt(totalCents: Int(seams.int("\(key).totalCents", default: 0)))
///     }
///
/// Every field read through `seams` under the synthesized key is recorded, domain-sweepable
/// (`Seam("API.fetch.totalCents", .int(0 ... 99_999))`), and identical on replay. An undeclared
/// required custom type traps fail-fast at the first call, naming the declaration to write.
///
/// `as:` optionally spells the generated class name, which `names: prefixed(Traced)` fixes to
/// `Traced<ProtocolName>` at every scope — the compiler rejects any other spelling as not covered
/// by the macro (same rule as `@TracedForwarder`).
@attached(peer, names: prefixed(Traced))
public macro TracedDouble(label: String, as generatedName: String? = nil) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "TracedDoubleMacro")

/// Instruments a single method with entry/exit trace capture. Normally applied automatically by
/// `@Traced`; usable directly for selective instrumentation. The argument is the stable type label
/// used to build the event name `"<typeLabel>.<method>"`. Pass `timed: true` to also record the
/// method's duration as a signpost interval.
///
/// `declaredBy` names the concrete type the method belongs to, which the *label* deliberately doesn't:
/// with it and the expansion's own file, the body registers a `TraceOrigin` when it runs, so a verdict
/// can say which sources its covered labels came from. `@Traced` fills it in; a hand-written
/// `@TracedMethod` may leave it off and lose only the type half of that line.
@attached(body)
public macro TracedMethod(_ typeLabel: String, timed: Bool = false, declaredBy: String? = nil) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "TracedMethodMacro")

/// Records every committed write to a **stored** property as a `stateChange` trace event, via a
/// `didSet` observer. Normally applied automatically by `@Traced`; usable directly for selective
/// instrumentation. The event label is `"<typeLabel>.<name>"`, the value is the property's committed
/// value (what an observer of the property would read at that moment), and writes during `init`
/// never record — observers don't fire there. `declaredBy` feeds the audit's origin map, as on
/// `@TracedMethod`.
@attached(accessor, names: named(didSet))
public macro TracedProperty(_ typeLabel: String, declaredBy: String? = nil) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "TracedPropertyMacro")

/// Marks a method inside a `@Traced` type to also record its duration as a signpost interval — the
/// method-level opt-in for timing. It is a no-op on its own; `@Traced` reads it when instrumenting.
///
///     @Traced final class CartService {
///         @Timed func checkout() -> Receipt { ... }   // traced *and* timed
///         func addItem(...) { ... }                    // traced only
///     }
///
/// For timing a *sub-region* of a method (finer than a whole method), use `Haruspec.interval` instead.
@attached(peer)
public macro Timed() =
    #externalMacro(module: "HaruspecMacroPlugin", type: "TimedMarkerMacro")

/// Generates a traced 1:1 forwarding shim from a pasted Obj-C "Generated Interface".
///
/// `@Traced` can't annotate an Obj-C class, so bringing a legacy Obj-C type under structural capture
/// otherwise means hand-writing a Swift shim that forwards every method and re-emits the trace events.
/// Instead, paste the class's Clang-imported signatures (IUOs and all) into a `protocol` and attach
/// this macro; it emits, as a peer, a `final class` conforming to the protocol that wraps the Obj-C
/// object and forwards each requirement — instrumented with the *same* `call`/`ret` events `@Traced`
/// emits, so the forwarder's trace aligns with a `@Traced` port of the same behavior:
///
///     @TracedForwarder(wrapping: CartManager.self, label: "Cart")
///     protocol Cart {
///         func add(_ product: Product!, quantity: Int)
///         func checkout() -> Receipt!
///     }
///     // → final class TracedCart: Cart { … forwards to a CartManager, traced as "Cart.add" etc. }
///
/// `wrapping:` is the Obj-C class to wrap; `label:` is the stable trace label (match the port's
/// `@Traced("<label>")` so their events align); `as:` optionally names the generated type (default
/// `"Traced" + <protocolName>`). Because the protocol keeps the imported IUOs verbatim, a
/// `checkout() -> Receipt!` forwards as a bare `__wrapped.checkout()` — no force-unwrap.
/// The generated type name is declared as `prefixed(Traced)` rather than `arbitrary`: Swift forbids a
/// peer macro from introducing *arbitrary* names at file scope (where a pasted-interface protocol
/// naturally lives), but a known prefix is allowed there. The name is therefore always
/// `Traced<Protocol>` — the compiler rejects a custom `as:` spelling anything else, at every scope,
/// as not covered by the macro.
///
/// `shared:` lets a **singleton** wrapped type declare its accessor so the forwarder self-wires to the
/// real instance: `@TracedForwarder(wrapping: InventoryLedger.self, label: "Inventory", shared: "shared()")`
/// generates an `init` defaulting to `InventoryLedger.shared()`, so `TracedInventorySeam()` needs no
/// argument. Absent `shared:`, the init defaults to a fresh `wrapping()` (the right choice for a SUT the
/// spec constructs itself). The forwarder is *role-neutral* — it records the same `call`/`ret` whether
/// it wraps the system under test or an injected collaborator; classifying a boundary as a durable
/// collaborator is a spec concern, not a property of this declaration.
///
/// The generated type is an `NSObject` subclass, so it can back an Obj-C `id<Protocol>` injection point
/// when the pasted protocol refines an `@objc` seam (Swift forbids conforming to an `<NSObject>`-refining
/// protocol without inheriting `NSObject`). This is inert for a Swift-only forwarder like `TracedCart`.
@attached(peer, names: prefixed(Traced))
public macro TracedForwarder(
    wrapping: Any.Type,
    label: String,
    as generatedName: String? = nil,
    shared: String? = nil
) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "TracedForwarderMacro")

/// Derives a spec's op catalog from the boundary protocol — the mechanical two-thirds of an
/// `.operations` block (method bindings, type-heuristic domains) generated so only the semantic
/// residue is authored.
///
///     @DerivedOps
///     protocol Cart: AnyObject {
///         func add(_ product: Product!, quantity: Int) async
///         func applyPromo(_ code: String!) async -> Bool
///         func checkout() async -> Receipt!
///     }
///     // → enum DerivedCart: one DerivedOp per requirement
///
///     Spec<Cart>("cart").system { … }.operations(derivedFrom: DerivedCart.self) {
///         Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
///         Amend("checkout").last()
///     }
///
/// The heuristics: numeric parameters default to a magnitude ladder (`SeamDomain.intMagnitudes` /
/// `.doubleMagnitudes` — decade boundaries ±1 as scheduled edges, log-uniform random fill, negatives
/// included, spans width-fitted per type); `Bool` defaults to both values; every derived op repeats
/// `0 ... 3` so op *absence* is explored; return values are discarded (the trace is what a
/// differential compares). Domains the engine defaulted are marked "derived default" on every verdict.
///
/// What is deliberately *not* derived: a `String` parameter is pending — its interesting values are
/// magic ("SAVE10"), and a random default would sweep only the nothing-matches branch — so an
/// unresolved one traps at spec construction naming the declaration to write. A custom-typed
/// parameter maps to `.generated(T.self)` and requires the model's `SeamGenerated` conformance (the
/// compile error is the prompt to write one). Ordering constraints are never derived: an "invalid"
/// ordering is a valid differential probe, so `.after`/`.last` stay authored. Property, `static`,
/// and generic requirements are skipped — replace those with authored `Op`s if they matter.
///
/// With a `@TracedForwarder` sibling and a pasted `init` requirement, the *system* derives too:
/// the catalog carries a factory built on the forwarder's `init(resolving:)`, so
/// `Spec(_:derivedFrom:)` needs no `.system { }` — collaborators resolve to their `@TracedDouble`
/// doubles by declared boundary, a `NotificationCenter` parameter takes the capture's isolated
/// center, and anything unresolvable traps naming the authored wiring to write.
@attached(peer, names: prefixed(Derived))
public macro DerivedOps() =
    #externalMacro(module: "HaruspecMacroPlugin", type: "DerivedOpsMacro")

// MARK: - @Seamed (un-injected reach)

/// Routes a type's **un-injected** nondeterminism through the harness. Legacy code that calls a bare
/// `Date()` / `Date.now` / `UUID()` — with no injected clock or generator — is rewritten (methods only,
/// and only where such a call is present) to read the ambient `Seam` cassette instead:
///
///     import HaruspecSeams
///     import HaruspecMacros
///
///     @Seamed final class LegacySession {          // no constructor parameter, no protocol
///         func start() { let now = Date(); ... }    // `Date()` → `Seam.now()` under #if DEBUG
///     }
///
/// The rewrite is emitted **only under `#if DEBUG`**, so release builds keep the original bare calls
/// and production is untouched. With no cassette bound (`Seam.bind`), the calls pass through to
/// the real API. Requires `import HaruspecSeams` at the use site for the expansion to resolve.
@attached(memberAttribute)
public macro Seamed() =
    #externalMacro(module: "HaruspecMacroPlugin", type: "SeamedMacro")

/// Rewrites a single method's bare seam calls to the ambient `Seam` (DEBUG-only). Normally
/// applied automatically by `@Seamed`; usable directly for selective opt-in.
@attached(body)
public macro SeamedMethod() =
    #externalMacro(module: "HaruspecMacroPlugin", type: "SeamedMethodMacro")
