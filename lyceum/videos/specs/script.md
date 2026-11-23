---
title: "Specs: the one thing you write"
status: draft 1
updated: 2026-10-11
# Written form → spoken form, applied only to the text sent to the voice.
pronounce: {}
# Subtitles: a track viewers turn on, or `captions: burned` to draw them into the picture.
# captions: burned
# The look: the dark canvas, or `theme: paper`, a light, formal look for presentations.
# theme: paper
# The files this video explains, one per line: `- path (what the video takes from it)`.
# `lyceum stale` watches them; `lyceum stale --mark specs` records the commit they were checked at.
sources:
  - docs/specs.md (the concept doc this video pairs with, same story in the same order)
  - README.md (the two shapes table, the Spec<Cart> amendment block, naming a spec only when several share a protocol, check by initializer, the @Continuous card)
  - Sources/Macros/Macros.swift (one stamp on a pasted protocol, its three peers, the label every role records under, @Continuous)
  - Sources/MacroPlugin/HaruspecMacro.swift (the stamp attaches to protocols only and emits forwarder, catalog and double)
  - Sources/MacroPlugin/Catalog.swift (one operation per method requirement, arguments named from the signature, var requirements become observed properties)
  - Sources/Spec/Spec.swift (Spec init taking the amendment block, name defaults to the stamp label, once, repeating, after, requires, last, vary, Ordering, Budget)
  - Sources/Spec/DerivedOps.swift (type heuristics, a String stays pending, the pending-argument trap text, Amend, a full Op replaces its derived twin, derived specs explore by default)
  - Sources/Spec/Exploration.swift (derived defaults of 50 orderings and 1200 runs, the magnitude spans, both axes scaled by the same factor)
  - Sources/Seams/SeamDomain.swift (the magnitude ladder of boundary values, edges before middles)
  - Sources/Spec/StateSampler.swift (observed properties read after construction, after every operation and after held work)
  - Sources/Spec/Qualification.swift (the derived default note on a verdict's seams line)
  - Sources/Spec/SpecCapture.swift (the capture's recording notification center handed to the subject)
  - Sources/Spec/BaselinedSpec.swift (baselined(on:) by type, by initializer, or by closure)
  - Sources/Spec/Check.swift (check by type, expecting a verdict, the report titled spec slash build)
  - Sources/Spec/InitializerBuilds.swift (check(Port.init) for a port whose dependencies differ)
  - Sources/Spec/SpecRunner.swift (the golden run first, every probe on both sides, a stable red shrinks its ordering by dropping operations)
  - Sources/MacroPlugin/Continuous.swift (@Continuous emits the suite that records and replays the spec)
  - Tests/SpecTests/DerivedOpsTests.swift (a full Op replacing its derived twin, the vary override with Ordering and Budget)
  - example-xcode-migration/LegacyApp/Features/Cart/CartManager.h (the legacy Objective-C cart interface)
  - example-xcode-migration/LegacyAppTests/SubjectBoundaries.swift (the stamped Cart protocol with its pasted initializer, the conformance lines)
  - example-xcode-migration/LegacyAppTests/CartMigrationSpec.swift (the three amendment lines, the campaign suite with check and expecting diverged)
  - example-xcode-migration/LegacyAppTests/CollaboratorBoundaries.swift (the Product generator and the catalogue of product codes)
verified:
  ".": "a4832ac4c6f3"
  example-xcode-migration: "c177f1d3f947"
---

<!--
Format: one `## NN · id — Title` per scene. `> Visual:` lines describe the animation; every other
paragraph is narration, spoken in order. The narration is the only text sent to TTS, so it is
written for the ear: no identifiers that read badly aloud, short sentences. The intent above the
first scene is never narrated.
-->

# Intent

- **Point:** a spec is the one thing you write, and most of it writes itself: stamp the pasted
  protocol, amend only what a signature can't say, and let the test pick the baseline and check each
  port.
- **Angle:** opens on the dogfood cart's whole spec (three amendment lines) and asks where
  everything else comes from. Builds stamp → operations and effects read off the signatures → the
  amendments → binding and checking → how the declaration becomes exploration → the same spec in
  the continuous shape. Ends back on the three lines.
- **Length:** about 5 minutes.
- **Notes:**
  - Adopter level throughout: what you write and what you get, never how the macro expands. The
    forwarder, catalog and double are named once, as what the stamp gives you.
  - Out of scope, pointed at instead: how collaborators are injected and resolved (the seams video),
    reading a verdict or declaring intent (the verdicts video). The cart spec's `.comparing` and
    `.provides` lines stay on screen but dimmed and tagged "seams video".
  - The running example is the dogfood cart (Objective-C `CartManager`, Swift `SwiftCart`), which is
    the cart the README's snippets describe. The engine has no stamped cart with these operations.
  - Shrinking: only the failing ordering shrinks (operations dropped while it still diverges). The
    seam values are reported as found. Never claim a minimal value.
  - Numbers: derived defaults are "up to 50 orderings, 1,200 runs", integers ladder to ±10,000.
    Don't put the dogfood cart's own run counts on screen; they depend on settle points (seams
    video) and were not re-measured for this script.
  - Look: baseline blue (`CartManager`), candidate pink (`SwiftCart`, `SwiftCartBuggy`), verdict
    pills in their fixed colours. Stamp-generated chips in a neutral accent.

## 01 · three-lines — Three lines for a cart

> Visual: Dark canvas. Left (x 80–900): a `CodeCard` "CartManager.h" with a baseline-blue border,
> simplified (initializers and other members omitted):
> ```objc
> @interface CartManager : NSObject
> - (void)addProduct:(Product *)product quantity:(NSInteger)quantity;
> - (void)removeSku:(NSString *)sku;
> - (BOOL)applyPromo:(NSString *)code;
> - (Receipt *)checkout;
> @end
> ```
> On "Swift port", a file chip "SwiftCart.swift" (candidate pink) slides in at right (x 1020–1840).
> On "expected totals", three grey cards stack in the centre: "expected values", "mocks", "one
> assertion per path"; on "you don't", all three strike through and fade. On "the expected value",
> the blue card gains a tag "the oracle". On "the same inputs", a stream of input dots enters from
> the top and splits into both sides; two short trace strips run under them with matching rows. On
> "a spec", both sides slide up and a `CodeCard` "CartMigrationSpec.swift" writes on centre-bottom,
> real lines with comments and the trailing modifiers removed (scene 4 shows them):
> ```swift
> Spec<Cart> {
>     Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
>     Amend("removeSku").varying("sku", over: .oneOf(Catalog.skus))
>     Amend("checkout").last()
> }
> ```
> On "three lines", the three `Amend` lines highlight. On "everything else", four ghost chips with
> question marks float around the card: "operations?", "values?", "effects?", "which build?".

Here's a shopping cart written in Objective-C, and its new Swift port. Before the port ships, you
want to know it behaves exactly like the original.

The usual way is to write down what the original does: expected totals, mocks, one assertion per
path. With Haruspec, you don't. The original is the expected value. Both carts get the same inputs,
and their behavior is compared.

What you write instead is a spec: how to interrogate the cart. For this cart, its heart is three
lines. This video is about where everything else comes from.

## 02 · stamp — Paste the interface, stamp it

> Visual: Left (x 80–1000): a `CodeCard` "SubjectBoundaries.swift", simplified (initializer
> abridged, comments removed):
> ```swift
> @Haruspec
> protocol Cart: AnyObject {
>     init(
>         inventory: InventoryReserving,
>         analytics: AnalyticsTracking,
>         notificationCenter: NotificationCenter,
>         …
>     )
>     func add(_ product: Product!, quantity: Int) async
>     func removeSku(_ sku: String!) async
>     func applyPromo(_ code: String!) async -> Bool
>     func checkout() async -> Receipt!
>     var itemCount: Int { get async }
>     var subtotalCents: Int { get async }
> }
> ```
> On "Paste the cart's interface", the body writes on; on "initializer included", the `init(` block
> marks; on "stamp it", the `@Haruspec` line glows. On "both conform", a small real card writes on
> below it with the two lines `extension CartManager: Cart {}` (blue left rule) and
> `extension SwiftCart: Cart {}` (pink left rule). On "never imports Haruspec", a tag on the pink
> line: "SwiftCart.swift imports Foundation only". On "three things", three chips slide out to the
> right (x 1100–1840) on connector lines from the `@Haruspec` line: `TracedCart` "forwarder",
> `DerivedCart` "catalog of operations", `DoubleCart` "stand-in". On "records every call", a
> two-row trace strip (simplified, illustrative values) drops under `TracedCart`:
> `Cart.applyPromo · call · code: "SAVE10"` and `Cart.applyPromo · return · true`. On "catalog of operations", `DerivedCart` glows. On "the seams
> video", `DoubleCart` dims and takes a tag "→ seams video". On "the cart is the subject",
> `TracedCart` brightens and the other two settle back.

It starts in your test target. Paste the cart's interface into a protocol, initializer included, and
stamp it with the Haruspec attribute. Then declare that the original and the port both conform: one
line each. The product code never imports Haruspec.

The stamp is a macro. From that one protocol, it generates three things. A forwarder, which wraps
either cart and records every call, its arguments and its return value. A catalog of operations to
drive. And a stand-in, for when some other class takes a cart as a collaborator. That's the seams
video. Here, the cart is the subject.

## 03 · derived — Read off the signatures

> Visual: The protocol card shrinks to the left (x 80–760). Right (x 840–1840): a table with
> columns "requirement", "operation", "argument → domain". On "Every method becomes an operation",
> four rows write on: `add(_:quantity:)` → `add`; `removeSku(_:)` → `removeSku`; `applyPromo(_:)` →
> `applyPromo`; `checkout()` → `checkout` (domain cell "no arguments"). On "a domain from its type",
> the domain cells fill: `quantity` "magnitude ladder", `product` "its own generator", `sku` and
> `code` left empty and amber. On "ladder of magnitudes", an inset number line under the table lights
> outward from zero: `0`, `±1`, `±9 ±10 ±11`, `±99 ±100 ±101`, `±999 ±1,000 ±1,001`, `±9,999 ±10,000`.
> On "both values", a small side chip "Bool → false, true". On "its own generator", the `product` cell
> expands to `Product.sku ∈ BEANS, COFFEE, FILTER, MUG`. On "zero to three times", each of the first
> three rows gets a badge "× 0…3", and a mini ordering row writes on below: `checkout` alone, caption
> "an empty cart". On "derived default", a qualification line writes on at the bottom (format from
> Qualification.swift, values illustrative): `seams: add.quantity (3 positions · derived default)`.
> On "effects worth observing", the table fades back and three lanes appear beside the protocol
> card, each linked to the line it comes from: "calls and returns" (to the `func` lines, via
> `TracedCart`), "notifications" (to `notificationCenter: NotificationCenter`), "properties" (to
> the two `var` lines). On "read after every operation", the properties lane writes on a row of
> operation ticks with a snapshot dot after each (`itemCount 0 → 2 → 2 → 0`, illustrative); on
> "the path is compared", the dots join into one line; on "where it ended", the last dot alone takes
> a ring labelled "end state", smaller than the line it sits on.

The catalog comes straight from the signatures. Every method becomes an operation. Every argument
gets a domain from its type.

A whole number gets a ladder of magnitudes, out to ten thousand both ways, stepping either side of
each power of ten, where off-by-one bugs live. A Boolean gets both values. A model, like the
product, is built by its own generator. And each operation repeats zero to three times, so even a
checkout on an empty cart gets tried. Any domain the engine chose is marked derived default on the
verdict, so a green over guessed inputs says so.

The effects worth observing come from the same paste. Calls and returns, at the forwarder.
Notifications, through the center the initializer takes. And each property, read after every
operation, so the path is compared, not just where it ended.

## 04 · amend — Amend what a signature can't say

> Visual: The table returns with the `sku` and `code` cells amber, labelled "pending". On "random
> text", random strings (`x7Qa`, `ploo`, `ZZ9`) stream into a three-exit branch drawn for
> `applyPromo`: "match", "case-insensitive match", "no match"; every string falls through "no match".
> On "hollow", a dashed EQUIVALENT pill (green) appears beside it and cracks. On "binding the spec
> traps", a red trap card writes on, quoted from DerivedOps.swift with the names filled in: "derived
> op 'applyPromo' has no domain for 'code: String' — a String has no honest default. Declare its
> values: Amend("applyPromo").varying("code", over: .oneOf(…))". On "That's what the three lines
> are", the trap card clears and the `CodeCard` "CartMigrationSpec.swift" writes on, real lines with
> comments removed:
> ```swift
> Spec<Cart> {
>     Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
>     Amend("removeSku").varying("sku", over: .oneOf(Catalog.skus))
>     Amend("checkout").last()
> }
> .comparing(Comparison(concurrency: .perDomain))
> .provides((() -> UUID).self) { _ in Minted.identifiers() }
> .provides((() -> Date).self) { _ in { Minted.instant } }
> ```
> The last three lines are dimmed with a bracket tag "seams video". On "save ten", the first `Amend`
> line highlights, and the branch's exits light one by one on "a match", "a case-insensitive match"
> and "no match". On "the remove operation", line 2 highlights with four chips beneath it: `BEANS`
> `COFFEE` `FILTER` `MUG`. On "it runs last", line 3 highlights and the table's checkout badge flips
> from "× 0…3" to "last · once". On "The rest shapes", a strip writes on along the bottom:
> `.once()` `.repeating(_:)` `.after(_:)` `.requires(_:)`; on "breaks on purpose", `.after` takes the
> tag "soft"; on "never does", `.requires` takes the tag "hard gate". On "replaces its derived twin",
> the spec card slides aside for a real card from Tests/SpecTests/DerivedOpsTests.swift:
> ```swift
> Spec<MeteredCart>("derived.replace") {
>     Op(
>         "add",
>         varying: .oneOf("COFFEE").named("sku"),
>         .int(1 ... 5).named("quantity")
>     ) { cart, sku, quantity in
>         cart.add(sku: sku, quantity: quantity)
>     }
>     Amend("total").last()
> }
> ```

Strings get nothing. A string's interesting values are magic words, like a promo code, and random
text only ever reaches the branch where nothing matches. A green from that would be hollow. So a
string stays pending, and binding the spec traps, naming the line to write.

That's what the three lines are. Amend apply promo, varying the code over save ten, the same in
lowercase, and nope: a match, a case-insensitive match, and no match. Amend the remove operation,
varying its product code over the catalogue. And amend checkout: it runs last.

The rest shapes the orderings: run once, repeat, follow another operation, which exploration still
breaks on purpose, or require one, which it never does. When the call itself must differ, a full
operation in the block replaces its derived twin.

## 05 · bind — The test picks the baseline

> Visual: The three-line spec card shrinks to the left (x 80–760), with a dashed empty slot beneath
> it labelled "implementation?". On "baselined on", `.baselined(on: CartManager.self)` slides into
> the slot and the slot turns baseline blue. On "the pasted initializer", a small flow writes on to
> its right: "CartManager" (blue) → `init(inventory:…)` → three grey collaborator chips plug in,
> tagged "resolved · seams video" → a `TracedCart` box. On "each port is one check", a `CodeCard`
> "CartMigrationSpec.swift" writes on at right (x 840–1840), simplified (audit line and doc comments
> removed):
> ```swift
> @Suite("cart.objc-to-swift", .campaign)
> struct CartMigrationTests {
>     private let subject = CartMigrationSpec().baselined(on: CartManager.self)
>
>     @Test func swiftPortIsIndistinguishableFromTheBaseline() async throws {
>         try await subject.check(SwiftCart.self)
>     }
>
>     @Test func truncationBugStillDiverges() async throws {
>         try await subject.check(SwiftCartBuggy.self, expecting: .diverged)
>     }
> }
> ```
> On "built exactly the same way", "SwiftCart" (pink) runs through the same flow into `TracedCart`.
> On "its own initializer", one real line from the README writes on beneath the card:
> `try await subject.check(SwiftCatalogPrefetcher.init)`. On "expecting diverged", the second test
> highlights and a DIVERGED pill (red) lands beside it, tagged "expected". On "still bites", the
> pill pulses once. On "comes from the stamp", the `Spec<Cart>` token takes a tag `name: "Cart"`, and
> two chips appear: a plan file "Cart.plan.json.gz" and a report title "Cart/SwiftCart". On "name
> each", a ghost line from the README: `Spec<Cart>("cart.promo") { … }`.

The spec names no implementation. It describes the protocol. The test chooses what to trust, with
baselined on.

Hand it the original's type. It's built through the pasted initializer, each collaborator resolved
for you, and wrapped in the forwarder. Then each port is one check, by its type, built exactly the
same way. A port whose dependencies differ is checked through its own initializer instead.

A check that should go red says so: expecting diverged. A kept bug proves the oracle still bites.

And the spec's name comes from the stamp: Cart. It titles reports and plans. Only when two specs
interrogate one protocol do you name each.

## 06 · explore — From declaration to exploration

> Visual: Top band (y 80–260): one ordering `add → removeSku → applyPromo → checkout` runs against
> "CartManager" (blue) alone; each read drops a value onto a tape labelled "what the cart reads". On
> "orderings", a column of ordering rows writes on at left (x 80–700): `add → add → applyPromo →
> checkout`, `applyPromo → add → checkout`, `checkout`, `removeSku → add → checkout`, and more fading
> down. On "seam variants", a row of value chips writes across the top of a grid (x 760–1840):
> `quantity=0 · code=SAVE10`, `quantity=-1 · code=NOPE`, `quantity=10000 · code=save10`, …; the grid
> fills in between. On "both carts", each cell splits into a blue half and a pink half and ticks
> green. On "enormous", the camera pulls back until the grid is a small patch in a vast faint field
> labelled "the declared space". On "twelve hundred runs", a budget box writes on: "derived spec ·
> up to 50 orderings · 1,200 runs". On "shrink together", the grid's width and height scale down by
> one factor, keeping its shape, captioned "both axes × √(budget ÷ full)". On "Edge values go
> first", the columns reorder so edge values (`0`, `±1`, `±10000`, `SAVE10`, `save10`, `NOPE`) sit
> leftmost; on "not ends", the right-most columns fade out. On "Vary changes any of it", a real card
> from Tests/SpecTests/DerivedOpsTests.swift:
> ```swift
> cartSpec("derived.equivalent").vary {
>     Ordering(max: 4)
>     Budget(runs: 160)
> }
> ```
> On "goes red", one grid cell turns red and its ordering lifts out (illustrative):
> `add → applyPromo → add → removeSku → checkout`. On "one at a time", the operations fade one by
> one; `removeSku` stays out, the others snap back when the red would vanish without them, leaving
> `add → applyPromo → add → checkout`. On "its own video", a DIVERGED pill (red) appears, tagged
> "→ verdicts video".

Here's what the engine does with it. First, the original runs once, to learn which values the cart
reads. Then it builds orderings, sequences of operations, and pairs each with seam variants, fresh
sets of those values. Every pair runs on both carts, with identical inputs.

The space is enormous, so a derived spec spends a budget: about twelve hundred runs, over at most
fifty orderings. Where it can't buy everything, both axes shrink together, because they find
different bugs. Edge values go first, so a small budget drops random middles, not ends. Vary changes
any of it.

And when a run goes red, the engine shrinks it, dropping operations one at a time while it still
diverges. Reading that verdict is its own video.

## 07 · continuous — The same spec, on every branch

> Visual: Left (x 80–900): a real `CodeCard` from the README:
> ```swift
> @Continuous(baseline: CartManager.self)
> struct CartMigrationSpec: SpecProviding {
>     var spec: Spec<Cart> { … }
> }
> ```
> Right (x 960–1840): the README's shapes table, two columns. On "the campaign shape", the left
> column lights: "Campaign · two implementations, one build". On "the continuous shape", the right
> column lights: "Continuous · one implementation, two builds". On "records", a box "main" emits a
> file chip "Cart.plan.json.gz"; on "replays", an arrow carries it into a box "your branch". On "the
> one thing you write", everything clears to a four-step strip across the middle: "stamp the
> protocol" → "amend what a signature can't say" → `.baselined(on:)` → `check(_:)`. On "Three lines,
> for a cart", the scene-1 spec card returns centre with its three `Amend` lines glowing. On "the
> seams video" and "the verdicts video", two end chips rise at bottom right: "Seams" and "Verdicts".

That's the campaign shape: two implementations, one build. The same spec also drives the continuous
shape. Put it in a type and mark it continuous, naming the implementation to watch. Its suite
records that behavior on main as a plan, and replays it against every branch.

So, the one thing you write. Paste and stamp the protocol. Amend what a signature can't say. Let the
test pick the baseline, and check each port. Three lines, for a cart. What the cart talks to is the
seams video. What comes back is the verdicts video.