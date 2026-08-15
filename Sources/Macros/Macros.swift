// Opt-in, zero-code method capture. Import alongside `HaruspecTrace`:
//
//     import HaruspecTrace
//     import HaruspecMacros
//
//     @Traced final class CartService { ... }   // every method now records call/args/return
//
// The generated bodies record to the ambient `TraceContext.current`, so instrumented types need no
// recorder property and are inert outside a capture window.

/// Instrument every instance method of a class (or actor) with entry/exit trace capture.
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
@attached(memberAttribute)
public macro Traced(_ typeLabel: String? = nil, timing: Bool = false) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "TracedMacro")

/// Instrument a single method with entry/exit trace capture. Normally applied automatically by
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

/// Mark a method inside a `@Traced` type to also record its duration as a signpost interval — the
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

/// Generate a traced 1:1 forwarding shim from a pasted Obj-C "Generated Interface".
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
/// naturally lives), but a known prefix is allowed there. The default name is always `Traced<Protocol>`;
/// a custom `as:` name must therefore also begin with `Traced` when the protocol is declared at file scope.
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
/// The generated name is `Traced<ProtocolName>` (or `as:`, which must equal that when the protocol is at
/// file scope — `names: prefixed(Traced)` covers only the prefixed protocol name, not an arbitrary one).
@attached(peer, names: prefixed(Traced))
public macro TracedForwarder(
    wrapping: Any.Type,
    label: String,
    as generatedName: String? = nil,
    shared: String? = nil
) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "TracedForwarderMacro")

// MARK: - @Seamed (un-injected reach)

/// Route a type's **un-injected** nondeterminism through the harness. Legacy code that calls a bare
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
