# Specs

A spec is the one thing you write. It says how to interrogate a boundary: which operations to drive, with which
inputs, in which orders. It names no implementation and states no expected values. A test binds the code you trust
as the baseline, and every port is driven through the same spec, with the same inputs, and compared against it.

Over a protocol stamped with `@Haruspec`, most of a spec derives from the protocol's signatures. What you write is
the part a signature cannot say.

## A spec at a glance

This is everything a test target writes to check a Swift port of an Objective-C cart. The app's `CartManager` and
its ports already declare these members, so nothing in the app changes and nothing there imports Haruspec.

```swift
import Foundation
import Haruspec
@testable import Shop
import Testing

@Haruspec
protocol Cart: AnyObject {
    init(notificationCenter: NotificationCenter)
    func add(sku: String, quantity: Int)
    func applyPromo(_ code: String) -> Bool
    func checkout() -> Int
    var itemCount: Int { get }
}

extension CartManager: Cart {}
extension SwiftCart: Cart {}
extension SwiftCartTruncating: Cart {}

@Continuous(baseline: CartManager.self)
struct CartMigrationSpec: SpecProviding {
    var spec: Spec<Cart> {
        Spec<Cart> {
            Amend("add").varying("sku", over: .oneOf("COFFEE", "MUG", "BEANS"))
            Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
            Amend("checkout").last()
        }
    }
}

@Suite("cart.objc-to-swift", .campaign)
struct CartMigrationTests {
    private let subject = CartMigrationSpec().baselined(on: CartManager.self)

    @Test
    func swiftPortIsIndistinguishableFromTheBaseline() async throws {
        try await subject.check(SwiftCart.self)
    }

    @Test
    func truncatingPortStillDiverges() async throws {
        try await subject.check(SwiftCartTruncating.self, expecting: .diverged)
    }
}
```

`Shop` stands for the app's module. The spec itself is the three `Amend` lines. The rest of this page is where
everything else comes from: the stamp, what it derives, the amendments, the binding, and what the engine does with
all of it.

## Stamp the boundary

Paste the subject's interface into a protocol in the test target, as Swift imports it (for an Objective-C class,
Xcode's generated interface of its header), and attach `@Haruspec`. Paste:

- the methods a spec should drive;
- the initializer, so the baseline and its ports can be built by type;
- the properties whose state is worth comparing, as `var` requirements.

Then conform the baseline and every port by extension, one line each. The members already exist, so the extension
is empty, and it is the line where a signature drift fails to compile. Adding a port adds a line.

The stamp is a macro that writes three peers beside the protocol. You rarely name them:

- `TracedCart`, the forwarder: it wraps any conformer, the baseline and every port alike, and records each call
  that crosses it. Both traces are shaped by the protocol, so a port's private helpers never show up.
- `DerivedCart`, the catalog of operations a spec derives (next section).
- `DoubleCart`, a stand-in for when another subject takes a `Cart` as a collaborator ([seams.md](seams.md)).

Every role records under one label, the protocol's name by default. `@Haruspec("Cart") protocol ShoppingCart` keeps
a renamed protocol matching its old recordings. `@Haruspec(timed: true)` also records each call's duration, for a
comparison's timing budgets. `@Haruspec(schedules:)` makes a queue protocol a thread seam ([seams.md](seams.md)).

A few things about pasting:

- A class satisfies a pasted `init` from an extension only when it is final. Mark an Objective-C baseline
  `__attribute__((objc_subclassing_restricted))`.
- Declaring a requirement `async` lets an actor port witness it, and a synchronous method still satisfies it.
- The catalog skips `static` and `class` members and generic methods. Drive those with an authored operation.
- `@Haruspec` attaches to protocols only; on anything else it is a compile error.

## What the stamp derives

### Operations and their domains

Every method requirement becomes one operation, labelled with the method's name, in declaration order. Each argument
is named by its parameter's internal name (`removeSku(_ sku: String)` gives `sku`), or by its position when it has
none, and gets a domain from its type:

| Parameter type | Derived domain |
| --- | --- |
| `Int`, `Int64`, `Int32`, `Int16`, `NSInteger` | a magnitude ladder over -10,000 ... 10,000 |
| `Int8` | the same ladder over -100 ... 100 |
| `UInt`, `UInt64`, `UInt32`, `UInt16` | the ladder over 0 ... 10,000 |
| `UInt8` | the ladder over 0 ... 100 |
| `Double`, `Float`, `CGFloat` | a magnitude ladder over -1,000 ... 1,000, fractional decades included |
| `Bool` | both values |
| a model conforming to `SeamGenerated` | built by its own factory |
| `String`, `NSString` | pending |
| anything else (a collection, a closure, a model with no factory) | pending |

The magnitude ladder tries zero, one and minus one, then a step either side of each power of ten, before anything
random: off-by-one and rollover bugs live there. A pending argument has no honest default. A string's interesting
values are magic words (a promo code, a status), and random text would only reach the branch where nothing matches,
so the derivation leaves it for you to declare rather than manufacture a green.

Each derived operation repeats zero to three times per sequence. Absence is part of the surface: it is what reaches
a checkout on an empty cart. A method whose last parameter is a completion block (and that is not `async`) derives
an operation that hands in a block and waits for its delivery.

Every domain the engine chose rather than you is marked `derived default` in the verdict's seams line, so a green
over guessed inputs says so.

### Effects

The effects compared come from the same paste:

- every call through the forwarder, with its arguments and what it returned or threw;
- every notification posted to the `NotificationCenter` the initializer takes, which resolves to the capture's own
  recording center (a post to `.default` is not seen);
- each `var` requirement, read after construction, after every operation, and after each piece of held work, so the
  path is compared as well as where it ended;
- every call into a stamped collaborator, through its double ([seams.md](seams.md)).

Three spec modifiers adjust what is compared. `.ignore(notifications: ["CartDidChange"])` drops a noisy channel
from both sides. `.observes(_:)` adds a property for a system the stamp does not describe. `.comparing(_:)` sets
aside what is not behavior, such as numeric jitter or the order of independent effects.

## Amend what a signature cannot say

The block after `Spec<Cart>` holds amendments to the derived operations. Each names an operation by label:

```swift
Spec<Cart> {
    Amend("add").varying("sku", over: .oneOf("COFFEE", "MUG", "BEANS")).repeating(0 ... 6)
    Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE")).after("add")
    Amend("checkout").last()
}
```

| Amendment | Effect |
| --- | --- |
| `.varying("code", over: domain)` | fills a pending argument, or replaces a derived default |
| `.last()` | runs last, exactly once |
| `.once()` | runs exactly once per sequence |
| `.repeating(2)`, `.repeating(0 ... 6)` | a fixed count, or a count that varies between sequences |
| `.after("add")` | prefers to follow `add`; exploration still breaks this on purpose in part of its sample |
| `.requires("add")` | never runs before `add`; for an operation that would crash out of order |

A domain's type must match the argument's: `.oneOf("A", "B")` or `.oneOf([String])` for a string, `.int(1 ... 20)`
or `.oneOf(1, 5, 10)` for any integer width, `.double(0 ... 1)` for a floating-point argument, and
`.generated(Product.self)` for a model. Domains are plain values, so a shared vocabulary is a `let`.

A model with no factory stays pending until you give it one. Conform it to `SeamGenerated`, and every operation
that takes it derives through the factory:

```swift
extension Widget: SeamGenerated {
    static func generated(from fields: FieldSeams) -> Widget {
        let widget = Widget()
        widget.size = Int(fields.int("size", in: 1 ... 5))
        return widget
    }
}
```

When the call itself must differ (a collection argument, a sequence of calls, an argument built from two others),
write a full `Op` in the block. It replaces its derived twin in place, and the other operations still derive:

```swift
Spec<Cart> {
    Op(
        "add",
        varying: .oneOf("COFFEE", "MUG").named("sku"),
        .int(1 ... 5).named("quantity")
    ) { cart, sku, quantity in
        cart.add(sku: sku, quantity: quantity)
    }
    Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
    Amend("checkout").last()
}
```

Narrow a derived argument with `Amend`, never with a `Seam` on its key (`add.quantity`): the two would declare one
key twice, and binding traps.

## Bind the baseline, check each port

A spec describes the protocol. The test chooses what to trust with `baselined(on:)`, which also settles the
derivation (and traps there if an argument is still pending). It takes three forms:

- `.baselined(on: CartManager.self)` builds the type through the pasted `init`, resolving each parameter, and wraps
  it in the forwarder;
- `.baselined(on: CartManager.init(notificationCenter:))` builds through an initializer reference, spelled with
  its labels when it is overloaded, and needs no pasted `init`;
- `.baselined { context in CartManager(notificationCenter: context.notifications) }` builds by hand.

Each parameter resolves to a resource the spec `.provides`, the capture's notification center, or the one stamped
double serving its type ([seams.md](seams.md)).

The bound spec checks ports. `check` builds the port the same way, prints the verdict under `spec/build` (here
`Cart/SwiftCart`), writes an HTML report, and throws unless the verdict is the one expected:

```swift
try await subject.check(SwiftCart.self)
try await subject.check(SwiftCartTruncating.self, expecting: .diverged)
```

Check by type when the port's initializer matches the pasted one. When its dependencies differ, check it through
its own initializer, as the README's prefetcher port is: `check(SwiftCatalogPrefetcher.init)`.

`expecting: .diverged` keeps a known bug as a counterexample, proof the oracle still bites. `declaring:` takes the
change a port is meant to make ([verdicts.md](verdicts.md)). `verify(candidate:)` returns the verdict without
throwing. Checking the baseline against itself is a good first test: a spec has to hold still before it can judge a
port.

A spec is named for its stamp's label, so `Spec<Cart> { … }` is `Cart`; an unstamped system is named for its type.
The name titles reports, names the recorded plan (`Cart.plan.json.gz`) and keys intent. When several specs
interrogate one protocol, name each: `Spec<Cart>("cart.promo") { … }`. Two specs claiming one name are refused
where they meet.

## How a spec becomes exploration

Each run drives the baseline and the port once, with identical inputs. A spec declares which runs are worth making:

1. **The golden run.** The baseline runs once first, reading each declared domain at an interior value. It records
   which seams the subject reads and how often, and every later variant changes only those values.
2. **Orderings.** An ordering is one sequence of operations that respects the declared structure: counts, `.last()`,
   `.requires(_:)`. Up to the cap, orderings are sampled evenly across the space, every combination of counts
   getting a draw before any gets a second, and a quarter of the sample breaks a declared `.after(_:)`.
3. **Seam variants.** Each ordering is paired with fresh sets of seam values. Edge values come first (every value of
   a `oneOf`, the ends of a range, the ladder's rungs), alternating with variants that move every seam at once, so
   a small budget drops random middles rather than edges.
4. **The budget.** `Budget(runs:)` bounds the total. When the declared space is larger, both axes scale down by the
   same factor, because orderings and values find different bugs.
5. **Settle schedules.** When the subject holds work on a stamped queue across the gap between two operations, part
   of the budget also decides where that work lands ([seams.md](seams.md)).

A derived spec explores by default: up to 50 orderings within 1,200 runs. An authored `.operations` list runs only
its declared order until `.vary` declares an `Ordering`, and without a budget each ordering gets 64 seam variants.
Appending `.vary { Ordering(max: 10); Budget(runs: 200) }` to a spec overrides either number.
`Ordering(max:repeating:)` sets the cap, and how often an operation with no declared count may repeat.
`Seam(key, domain)` in the same block sweeps a value no operation argument owns, such as a collaborator double's
return ([seams.md](seams.md)).

A divergence does not stop the sweep. Every probe runs, and the verdict reports the richest failing case. When the
baseline reproduces itself on that input, the failing ordering is shrunk, dropping operations one at a time while it
still diverges; the seam values are reported as the run found them. The verdict's `explored:` line says how much of
the space was covered, as in `3200 runs · 50 of 2520 orderings (2%) × 4 settle schedules × 16 seam variants`.

## Authoring operations instead

An unstamped subject, or a protocol whose surface is all properties (a view model's input and outputs), has no
operations to derive. Author the list with `.operations { … }`, as the README's promo cart does. Each `Op` takes the
same forms as a replacement in the amendment block, its arguments' domains declared where they are used and keyed
`<operation>.<name>` (or the argument's position, without `.named`). Construction and observed properties still
derive from a stamp when there is one. Authored operations and amendments are exclusive: a spec does one or the
other.

Write operations where nothing isolates them. A capture reads the main thread as the subject's doing, so it refuses
an operation whose closure runs on an actor: the subject's nonisolated code would read as main-thread work. Under
default `MainActor` isolation, mark the spec type `nonisolated`; a subject's isolated method is still reachable with
`await`.

## The same spec, continuously

A spec checks ports in the campaign shape and guards every branch in the continuous one. Declare it in a type
conforming to `SpecProviding` (a `spec` property and a no-argument initializer, in a file that imports `Testing`)
and mark it `@Continuous(baseline:)` with the implementation to watch, by type or by initializer. The attribute emits
a `CartMigrationSpecContinuous` suite that records the baseline's behavior as a plan on main and replays the plan on
a branch; an ordinary test run leaves it idle. Give the suites that check ports the `.campaign` trait, so they stand
down while a plan is recorded. [Checking a branch locally](../README.md#checking-a-branch-locally) covers the rest.

## When a spec will not derive or a check refuses

Every refusal names its fix. The common ones:

| The message starts | What to do |
| --- | --- |
| `derived op 'applyPromo' has no domain for 'code: String'` | amend it with `.varying`, give the model a `SeamGenerated` factory, or replace the operation with an `Op` |
| `'aplyPromo' matches no derived op` | fix the label; the message lists the derived ones. An operation the protocol does not declare means authoring the list |
| `'applyPromo' has no argument named 'cod'` | use the parameter's internal name, or its position when unnamed |
| `'add.quantity' is Int; the declared domain generates String` | pass a domain of the argument's type |
| `"add.quantity" is declared twice` | drop the `Seam` on a derived argument's key and amend the operation instead |
| `spec 'Cart' amends derived ops and authors its own` | keep the amendments or the `.operations` list, not both |
| `spec 'Cart' amends derived ops, but … carries no @Haruspec stamp` | stamp the protocol, or author the operations |
| `spec 'Cart' derives no construction` | paste the `init` into the protocol, or bind and check by initializer or closure |
| `SwiftCart does not conform to Cart` | add `extension SwiftCart: Cart {}` |
| `nothing serves InventoryReserving`, or several doubles serve it | stamp or provide the collaborator ([seams.md](seams.md)) |
| `two specs are named 'Cart'` | name each spec: `Spec<Cart>("cart.promo") { … }` |
| `op 'add' runs on the main actor` | write the operations in a `nonisolated` spec type |
| `expected diverged, got equivalent` (or any other pair) | the verdict missed `expecting:`; read the report ([verdicts.md](verdicts.md)) |
| `declared domain matched nothing` in a report | nothing read that key: check its spelling, or that the subject reaches it |

The derivation's refusals fire when the spec is bound or a port is named, before any run. Conformance and
resolution refusals fire at the first capture that builds the system. A verdict that is not the one expected is not
a refusal: the spec ran, and the report says what it found. See [verdicts.md](verdicts.md) for reading it, and
[../README.md](../README.md) for the two shapes and installation.
