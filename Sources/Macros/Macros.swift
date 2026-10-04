// The one stamp. Paste a boundary's interface into a protocol and attach it:
//
//     import Haruspec
//
//     @Haruspec protocol Cart: AnyObject { … }   // → TracedCart, DerivedCart, DoubleCart
//
// Everything the engine needs from a boundary is generated from that declaration, so product code
// carries no Haruspec attribute: the baseline and every port conform to the protocol and are
// wrapped by its forwarder.

import HaruspecTrace

/// The one stamp on a pasted boundary protocol: everything Haruspec needs from it, whichever role a
/// spec gives it.
///
/// - Parameters:
///   - label: The stable trace label, the root of every event any role records (`"Cart.add"`);
///     `nil` uses the protocol's name. Pass one to keep a renamed protocol matching its old
///     recordings (`@Haruspec("Cart") protocol ShoppingCart`), or when the name you want is taken.
///   - timed: `true` makes the forwarder also record each forwarded call's duration as a signpost
///     interval, which is what a spec's timing budgets (``Tolerance/timingBudgets``) compare. For a
///     region finer than one call, use ``Haruspec/interval(_:subject:isolation:_:)``.
///   - schedules: Makes the protocol a thread seam whose work is ordered this way; see below.
///
///     @Haruspec
///     protocol Cart: AnyObject {
///         init(inventory: InventoryReserving, notificationCenter: NotificationCenter)
///         func add(_ product: Product!, quantity: Int) async
///     }
///     // → TracedCart   the forwarder, when Cart is a spec's subject
///     //   DerivedCart  the op catalog, when a spec derives its operations from Cart
///     //   DoubleCart   the stand-in, when another subject takes a Cart
///
///     @Haruspec
///     protocol Inventory: InventoryReserving {
///         func reserve(sku: String, quantity: Int)
///     }
///     // → DoubleInventory serves InventoryReserving, so Cart's init resolves to it
///
/// The stamp names no role: a spec gives a protocol its role by using it, so a collaborator today
/// can be migrated as a subject tomorrow with nothing re-stamped. Every role records under the
/// label, so the forwarder and the double of one boundary emit the same event names.
///
/// Composition is by construction contract. A subject's pasted `init` names its collaborators, and
/// each resolves to the one double serving that type — the stamped protocol itself, or the protocol
/// it refines. A collaborator nobody stamped fails loudly at the first capture that builds the
/// subject, naming the stamp to write. The check is at run time because a macro reads only the
/// declaration it is attached to and cannot see whether another protocol was stamped.
///
/// **The forwarder** (`Traced<Protocol>`) wraps any conformer — the Obj-C baseline and every Swift
/// port alike — and forwards each requirement 1:1 with `call`/`ret` events, so both traces are
/// protocol-shaped by construction and a shipped port carries no Haruspec attribute. A spec over
/// `any <Protocol>` records through it automatically. A settable `var` requirement records each
/// write that crosses it; the wrapped object's internal writes are invisible to it. An `async`
/// requirement records as the isolation it forwards into (the wrapped actor, or `@MainActor` when
/// the requirement declares it). The forwarder is an `NSObject` subclass, so it can back an Obj-C
/// `id<Protocol>` injection point.
///
/// **The catalog** (`Derived<Protocol>`) is one op per method requirement, with bindings written
/// mechanically and domains by type heuristic: numbers default to a magnitude ladder, `Bool` to
/// both values, and every op repeats `0 ... 3` so absence is explored. A `String` stays pending — its
/// interesting values are magic (`"SAVE10"`) — and so does a model with no `SeamGenerated` factory;
/// either traps at spec construction, naming the declaration to write, only if a spec drives that
/// op. `var` requirements become observed properties. With a pasted `init`, construction derives
/// too, so `.baselined(on: LegacyType.self)` binds a baseline with no closure.
///
/// **The double** (`Double<Protocol>`) records each call and does nothing behind it: the
/// interaction at the boundary is the behavior a differential checks. A value-returning requirement
/// or a property read returns the seam `"<label>.<member>"` — the type's zero by default, swept when
/// a spec declares a domain for that key. A required custom type returns the factory the spec
/// declares with `.generates(_:_:)`, trapping at the first call when none was. Construct one with
/// `context.double(DoubleInventory.self)`, which also registers it as an injected collaborator.
///
/// **A scheduling protocol** (`schedules:`) is the project's own thread seam. Production conforms a
/// real queue to it (a `DispatchQueue`, the main queue, a task spawner); a subject takes it in its
/// `init` like any collaborator. The stamp emits only the double, which holds each enqueue in the
/// capture's ``WorkBacklog`` instead of running it on a thread, and the engine drains the backlog one
/// item at a time after the ops. Its requirements take one of five shapes, read off the signature:
///
///     @Haruspec(schedules: .serial)
///     protocol CartQueue: SerialQueueing {
///         func async(_ work: @escaping () -> Void)                     // held, run in order
///         func after(_ delay: TimeInterval, _ work: @escaping () -> Void) // held on virtual time
///         func notify(_ group: DispatchGroup, _ work: @escaping () -> Void) // held until the group empties
///         func sync(_ work: () -> Void)                                 // its held work, then inline
///     }
///
///     @Haruspec(schedules: .concurrent)
///     protocol Tasks: TaskSpawning {
///         func spawn(_ operation: @escaping @Sendable () async -> Void)  // an unstructured task, held
///     }
///
/// The discipline is the subject's requirement, so it lives on the type the subject depends on: work
/// handed to a `.serial` or `.concurrent` protocol records on the domain `.queue(label, serial:)`, and
/// work handed to a `.main` one records on `.main` and runs on the main thread.
@attached(peer, names: prefixed(Traced), prefixed(Derived), prefixed(Double))
public macro Haruspec(_ label: String? = nil, timed: Bool = false, schedules: ScheduleDiscipline? = nil) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "HaruspecMacro")

/// Emits `<Spec>Continuous`, a test suite that records, replays, or censuses the spec baselined on
/// `baseline` when the environment selects a mode. The spec stays implementation-free.
///
/// - Parameter baseline: The watched type, built through the boundary's pasted `init`.
///
/// The attribute is the test's declaration of which build CI watches.
/// The file must `import Testing`, and the struct must conform to `SpecProviding` and have a
/// no-argument initializer:
///
///     @Continuous(baseline: CartManager.self)
///     struct CartMigrationSpec: SpecProviding {
///         var spec: Spec<Cart> { … }
///     }
@attached(peer, names: suffixed(Continuous))
public macro Continuous(baseline: Any.Type) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "ContinuousMacro")

/// Runs a spec's continuous side in CI on the baseline `initializer` builds — see
/// ``Continuous(baseline:)``.
///
/// - Parameter initializer: The watched type's initializer reference, every parameter resolved per
///   capture.
@attached(peer, names: suffixed(Continuous))
public macro Continuous<each Parameter, Built>(baseline initializer: (repeat each Parameter) -> Built) =
    #externalMacro(module: "HaruspecMacroPlugin", type: "ContinuousMacro")
