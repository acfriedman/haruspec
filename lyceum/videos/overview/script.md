---
title: "Haruspec in five minutes"
status: draft 1
updated: 2026-10-11
# Written form → spoken form, applied only to the text sent to the voice.
pronounce: {}
# Subtitles: a track viewers turn on, or `captions: burned` to draw them into the picture.
# captions: burned
# The look: the dark canvas, or `theme: paper`, a light, formal look for presentations.
# theme: paper
# The files this video explains, one per line: `- path (what the video takes from it)`.
# `lyceum stale` watches them; `lyceum stale --mark overview` records the commit they were checked at.
sources:
  - README.md (the pitch, the best-effort caveat, the two shapes and their table, At a glance, installation, getting started, checking a branch locally, the verdict table)
  - Tests/SpecTests/SpecPrototypeTests.swift (the PromoCart protocol; GoodCart rounds the 10% discount, RoundBugCart truncates it; quantity ten hides the bug)
  - Sources/Spec/SpecTerminalReport.swift (the report lines: banner, explored, coverage, divergences, counterexample)
  - Sources/Spec/Qualification.swift (the qualification block lines: covered, seams, blind spots)
  - Sources/Spec/Exploration.swift (the explored line: runs, orderings, seam variants)
  - Sources/Spec/Spec.swift (authored operations explore only the declared order unless .vary declares Ordering; Spec { Amend } derives from the stamp)
  - Sources/Spec/SpecRunner.swift (verify(candidate:): baseline and candidate driven with the same inputs, no expected value)
  - Sources/Spec/BaselinedSpec.swift (baselined(on:) by type or by factory)
  - Sources/Spec/Check.swift (check(_:) on a conformer: the port carries no attribute)
  - Sources/Core/Verification.swift (an equivalent over a coverage gap resolves to CANNOT-VERIFY)
  - Sources/Core/DiffReport.swift (the four verdict banners)
  - Sources/Spec/UncontrolledSeam.swift (unstable: a value the subject makes up itself, a fresh identifier or a clock reading)
  - Sources/CLI/main.swift (exit codes 0, 3, 4, 5)
  - Sources/Local/LocalCheck.swift (records the merge base once per base commit, replays only the specs the change touches)
  - Scripts/haruspec (the launcher behind .haruspec/bin/haruspec init and check)
  - Package.swift (the Haruspec umbrella product)
verified: "a4832ac4c6f3"
---

<!--
Format: one `## NN · id — Title` per scene. `> Visual:` lines describe the animation; every other
paragraph is narration, spoken in order. The narration is the only text sent to TTS, so it is
written for the ear: no identifiers that read badly aloud, short sentences. The intent above the
first scene is never narrated.
-->

# Intent

- **Point:** You can't write the expected value for legacy code, and with Haruspec you don't have
  to: the code you already trust is the expected value. You write a spec, Haruspec drives the old
  and new code with the same inputs and compares what they do, and the verdict tells you whether
  anything changed and what it was measured over.
- **Angle:** Start from a test you can't finish (what should checkout return?). Flip it: the old
  code is the oracle. Show the two shapes, campaign and continuous. Run the README's promo cart to
  a one-cent DIVERGED, name the four verdicts in one breath, and give the three steps to start plus
  `haruspec check` on a branch. End by pointing at the specs, seams and verdicts videos and calling
  back to the unfinished test.
- **Length:** about 5 minutes.
- **Notes:**
  - This is the README in video form. Each concept gets one line here; depth belongs to `specs`,
    `seams` and `verdicts`. Don't explain derivation, seam injection or the qualification block
    beyond a sentence each.
  - Only what ships: the continuous shape is shown through the local `haruspec check`. No
    continuous integration or pull request gate claims.
  - At a glance: the README's snippet and output were regenerated on 2026-10-11 from a live
    `verify(candidate:)` run of exactly that spec (it gained `Ordering(max: 10)`). The report card
    shows those real lines, abridged: the stability, seams and failing-order lines are left out.
  - Narration says "equivalent", "diverged", "cannot verify", "unstable" in lowercase; the screen
    uses caps. Narration never says "README" (all caps): it says "the project's front page" or
    nothing.
  - Exact figures stay on screen (384 runs, 1798 against 1799); narration says "a few hundred
    runs" and "one cent".

## 01 · cold-open — What should checkout return?

> Visual: Dark canvas, 80 px margins. Left half (x 80 to 900): a code card with a file tab
> "LegacyCart.m" and a blue (baseline) header strip; its body is eight grey placeholder bars, no
> readable code, with one legible method name `checkout` on the sixth bar. Small caption under the
> card: "Objective-C · years old · works". On "port it to Swift", a second, empty card slides in at
> the right (x 1020 to 1840) with a pink (candidate) header strip and the tab "LegacyCart.swift", and
> a pink arrow draws from the first card to it.
> On "you start with a test", both cards shrink upward to the top third and a test card writes on
> at centre (illustrative, not real API):
> ```swift
> @Test func checkoutTotal() {
>     #expect(cart.checkout() == ???)
> }
> ```
> On "Nobody knows", the `???` pulses amber twice. On "what it does today", a thin blue arrow runs
> from the legacy card down to a small receipt chip "total: whatever it returns today". On "the
> oracle problem", a title writes on above everything: "the oracle problem".

Here's a shopping cart class. Objective-C, years old, and it works. You've been asked to port it to
Swift.

So you start with a test, and you stall on the first line. What should checkout return? Nobody
knows. The people who decided have moved on. All anyone knows is what it does today.

That's the oracle problem. A test needs something that knows right from wrong, and for legacy code,
nobody can write it down.

## 02 · the-idea — Your code is the expected value

> Visual: The test card from scene 1 shrinks to the top-left corner (x 80, y 80), `???` still
> visible. Two tall boxes fill the middle: left "baseline · legacy" in blue (x 160 to 760), right
> "candidate · port" in pink (x 1160 to 1760). On "the same generated inputs", one row of input chips
> above them (`addCoffee`, `promo`, `checkout`, and a seam chip `coffeeQty = 7`) splits into two
> identical rows that drop into both boxes. On "every call and return", each box drops a trace strip
> below it, rows writing on in step: "call addItem", "post CartChanged", "call checkout", "return";
> on "every notification it posts" the "post" rows glow; on "the state it leaves behind" a final row
> "state snapshot" writes on in each strip. On "compares the two", connector lines pair the rows
> across the gap, each with a green "=".
> On "No mocks", three chips write on in a row along the top: "mocks", "assertions", "expected
> values", each struck through on its own word ("No mocks", "No assertions", "No expected values").
> On "The legacy code is the expected value", the corner test card's `???` is replaced by a blue
> chip "baseline". On "differential testing", a label writes on under the boxes: "differential
> testing".
> On "best-effort oracle", everything dims and a quote card writes on at centre, from the README:
> "⚠️ Haruspec is not omniscient. It is a best-effort oracle." On "it says so", an amber outline
> traces the card.

Haruspec's answer is to stop asking. Whatever the old code does today is what correct means. So the
old code becomes the oracle.

Haruspec drives the old implementation and the new one with the same generated inputs. It records
what each does at its boundary: every call and return, every notification it posts, and the
state it leaves behind. Then it compares the two.

No mocks. No assertions. No expected values. The legacy code is the expected value. That's
differential testing.

One honest caveat, stated up front: this is a best-effort oracle, not an omniscient one. Where it can't see, it says so.

## 03 · two-shapes — Campaign and continuous

> Visual: Split screen, a thin vertical rule at x 960. Left panel title "Campaign", right panel
> title "Continuous", both dim until named.
> On "a campaign", the left panel lights: one rounded build box labelled "one build" holding two
> class boxes, "Legacy · Objective-C" (blue) and "Port · Swift" (pink), with a double-headed arrow
> between them labelled "live". On "an actor", a small second example cycles under the box:
> "serial queue → actor". On "the old code is deleted", the blue class box fades out and the pink one
> slides to centre with a check mark.
> On "continuous", the right panel lights: two build boxes stacked, "main" (blue) above "your
> branch" (pink). On "recorded once, as a plan", a document chip "plan" slides out of main; on
> "your branch replays it", an arrow runs from the plan into the branch box. On "merges", the branch
> box slides up into main, the plan chip flips to show a refresh glyph, and the label "next baseline"
> appears beside it.
> On "The same spec drives both", a single spec card writes on beneath both panels, with lines up to
> each. Bottom strip, from the README's table, small type: "Compares: two implementations, one build"
> (left) and "Compares: one implementation, two builds" (right).

You'll reach for it in one of two shapes.

The first is a campaign. You're rewriting something that mustn't change behavior: an Objective-C
class moving to Swift, or a serial queue becoming an actor. The old code and its port live in the
same build. The old one runs live as the baseline, and every port is checked against it, until the
port ships and the old code is deleted.

The second is continuous. There's one implementation and two builds: main, and your branch. Main's
behavior is recorded once, as a plan, and your branch replays it, to catch changes nobody meant to
make. When your branch merges, its behavior becomes the next baseline.

The same spec drives both.

## 04 · at-a-glance — A promo cart, end to end

> Visual: A code card fills the left two thirds (x 80 to 1240), title "promo-cart · the whole
> authored surface". Code from the README's At a glance, plus the `Ordering(max: 10)` line the
> README's output needs (from Tests/SpecTests/SpecVerdictSerializationTests.swift); the
> `print(verdict.report())` line is left off:
> ```swift
> let cart = Spec<PromoCart>("promo-cart")
>     .operations {
>         Op("addCoffee") { cart, seams in
>             cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
>         }
>         Op("promo") { $0.applyPromo() }
>         Op("checkout") { _ = $0.checkout() }.last()
>     }
>     .vary {
>         Seam("coffeeQty", .int(1 ... 20))
>         Ordering(max: 10)
>     }
>
> let verdict = await cart.baselined(on: makeLegacyCart).verify(candidate: makeSwiftPort)
> ```
> Highlights move with the words: "Add some coffee" → the `Op("addCoffee")` block; "Apply the
> promo" → `Op("promo")`; "always runs last" → `.last()`; "a seam" → both `"coffeeQty"` mentions,
> with `.int(1 ... 20)` glowing on "from one to twenty"; "every order the spec allows" →
> `Ordering(max: 10)`.
> Right third (x 1300 to 1840): an "explored" panel builds as the spec is read, a grid with two
> labelled axes, "orderings" (rows) and "coffeeQty 1 … 20" (columns). On "from one to twenty" the
> columns fill; on "every order the spec allows" six rows fill, and the label "6 orderings" writes
> on; on "some of them twice" one row's label expands to "addCoffee → addCoffee → promo → promo →
> checkout".
> On "The legacy cart is the baseline", `baselined(on: makeLegacyCart)` turns blue; on "Verify the
> Swift port", `verify(candidate: makeSwiftPort)` turns pink. On "No expected total anywhere", a
> scan line sweeps the card top to bottom and a chip lands under it: "expected values: 0".

Here's the whole authored surface for a small promo cart.

Three operations. Add some coffee. Apply the promo. Check out, which always runs last. The coffee
quantity is a seam: a value the oracle controls, swept from one to twenty. And the operations run
in every order the spec allows, some of them twice.

Then one line. The legacy cart is the baseline. Verify the Swift port against it.

Notice what's missing. No expected total anywhere. Nobody worked out what ten coffees and a promo
should cost.

## 05 · diverged — One cent

> Visual: Top band (y 80 to 300): two one-line code strips, real lines from
> Tests/SpecTests/SpecPrototypeTests.swift. Blue strip, labelled "legacy":
> `let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0`. On "truncates the
> discount", a pink strip writes on beneath it, labelled "port":
> `let discount = promo ? subtotal / 10 : 0`, with `/ 10` underlined in red.
> On "At ten coffees", a calculation chip at right: "10 × 999 = 9990 → discount 999 either way",
> with a green "=" between two small totals "8991" (blue) and "8991" (pink). On "doesn't stop at
> ten", a slider "coffeeQty" sweeps 1 to 20 across the band.
> On "diverged", the top band slides up and out and a terminal card writes on, line by line, filling
> the frame (x 80 to 1840). Real lines from the README's At a glance output (a live
> `verify(candidate:)` run of exactly the spec in scene 4), abridged (the stability, "seams" and
> failing-order lines are left out):
> ```text
> ❌ DIVERGED  promo-cart → promo-cart
>   explored: 384 runs · all 6 orderings × 64 seam variants
>   coverage: 100% of 4 declared boundaries · domain-swept 0%
>   covered: PromoCart — 3 ops · 384 probes
>   blind spots: not audited — capture completeness is unmeasured;
>                effect channels outside the recorded seams may exist
>   2 divergence(s):
>     ≠ CheckoutCompleted: total: baseline=1798 candidate=1799
>     ≠ PromoCart.checkout: value: baseline=1798 candidate=1799
>   ↳ counterexample: coffeeQty=1,1
> ```
> The banner line is red. On "one cent more", every `1798` turns blue and every `1799` pink. On "the
> total in the checkout notification", the `CheckoutCompleted` line highlights; on "the value
> checkout returns", the `PromoCart.checkout` line highlights. On "a quantity of one", the
> counterexample line highlights.
> On "what the verdict was measured over", a bracket draws down the left of the explored, coverage,
> covered and blind-spots lines, labelled "qualification block"; "how much was explored" lights the
> explored line, "covered" lights the coverage and covered lines, "could not see" lights the blind
> spots line. On "green or red", a ghost "✅ EQUIVALENT" banner in green crossfades over the red one
> for a beat, the bracketed block unchanged beneath it, then fades back.

Now suppose the port truncates the discount where the legacy code rounded it.

At ten coffees, the two carts agree to the cent, so a test written at ten would pass. Haruspec
doesn't stop at ten. Across a few hundred runs, the verdict comes back diverged.

The port charges one cent more. The report names both places that shows: the total in the checkout
notification, and the value checkout returns. Then the input that triggers it: a quantity of one.

And beneath it, what the verdict was measured over: how much was explored, what was covered, and
what the oracle could not see. Every verdict carries that block, green or
red.

## 06 · four-verdicts — Four answers, not two

> Visual: Four verdict pills in a row across the middle (equal widths between the 80 px margins),
> each with its exit code beneath in small mono type, from Sources/CLI/main.swift: "✅ EQUIVALENT ·
> exit 0" (green), "❌ DIVERGED · exit 3" (red), "⚠️ CANNOT-VERIFY · exit 4" (amber), "🌀 UNSTABLE ·
> exit 5" (violet). All start as outlines; each fills on its own word: "Equivalent", "Diverged",
> "Cannot verify", "Unstable". On "names the gap", a small amber chip "gap: named" hangs under
> CANNOT-VERIFY. On "a fresh identifier", a violet chip "fresh identifier" hangs under UNSTABLE; on
> "a clock reading", a second chip "clock reading" joins it.
> On "the worst thing", the pills dim and a balance writes on at centre: left pan "false alarm: an
> hour lost", right pan "false green: a bug shipped". On "ships a bug", the right pan drops hard. On
> "That's why", the CANNOT-VERIFY pill returns above the balance, glowing amber, with the caption
> "not enough seen → no green".

That's one of four verdicts. Equivalent: every probe matched. Diverged: behavior differs, and the
report says where. Cannot verify: capture or coverage fell short, so the oracle refuses to claim
what it didn't see, and names the gap. Unstable: identical runs disagreed, usually because the
subject made up a value itself, like a fresh identifier or a clock reading.

Why four? Because the worst thing a tool like this can do is print green over behavior it never
saw. A false alarm costs you an hour. A false green ships a bug past a check you trusted. That's why
it would rather say cannot verify.

## 07 · getting-started — Three steps, then a branch

> Visual: Three step cards stacked down the left 60% (x 80 to 1150), each with a large numeral,
> writing on as named. Code is from the README; the stamp line is simplified.
> Card 1, "Add the package", on "Add the package":
> ```swift
> .package(url: "https://github.com/acfriedman/haruspec.git", branch: "main")
> .product(name: "Haruspec", package: "haruspec")
> ```
> Card 2, "Write a spec", on "Write a spec": first `@Haruspec protocol Cart: AnyObject { … }`
> (simplified), and on "derive from its signatures" a fan of four faint blank chips
> drops out of it, labelled "one operation per requirement"; then on "says only what a
> signature can't":
> ```swift
> Spec<Cart> {
>     Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
>     Amend("checkout").last()
> }
> ```
> with the `.oneOf(…)` highlighted on "which promo codes matter" and `.last()` on "checkout runs
> last".
> Card 3, "Check", on "Then check":
> ```swift
> let subject = spec.baselined(on: CartManager.self)
> try await subject.check(SwiftCart.self)
> ```
> `CartManager` blue, `SwiftCart` pink. On "no Haruspec attribute", a small "class SwiftCart: Cart"
> chip with a green tick and "no attribute" sits under the card.
> On "the continuous shape", a terminal panel writes on in the right 40% (x 1210 to 1840):
> ```text
> $ .haruspec/bin/haruspec init     # once
> $ .haruspec/bin/haruspec check    # any branch
> ```
> On "mark the spec continuous", a chip `@Continuous(baseline: CartManager.self)` slides from the
> terminal to Card 2. On "where your branch left main", a tiny branch diagram appears under the
> terminal (a blue dot "merge base" on a main line, a pink branch off it); on "your change touches",
> two of four spec chips beneath light pink and the other two grey out, labelled "untouched".

Starting takes three steps.

Add the package with Swift Package Manager, and depend on one product, Haruspec.

Write a spec. Stamp the protocol your class already speaks, and its operations derive from its
signatures. The spec says only what a signature can't: here, which promo codes matter, and that
checkout runs last.

Then check. In a test, bind the legacy class as the baseline and check the port. The port carries
no Haruspec attribute. Conforming to the protocol is the whole adoption.

For the continuous shape, opt the repository in once, mark the spec continuous, and run haruspec
check on any branch. It records behavior where your branch left main, then replays only the specs
your change touches, on your machine.

## 08 · next — Where to go from here

> Visual: Three video cards in a row, centred, writing on as named, each with a title and a one-line
> subtitle: "Specs · the one thing you write" (on "Specs"), "Seams · what the oracle controls" (on
> "Seams"), "Verdicts · the four answers, and the change you meant" (on "And verdicts"). The seams card
> carries a small violet UNSTABLE chip; the verdicts card shows the four colour dots.
> On "that test we couldn't finish", the cards dim and the scene 1 test card returns at centre:
> `#expect(cart.checkout() == ???)`. On "already knew", the `???` is replaced by a blue chip "the
> old code", and the frame holds.

That's Haruspec in five minutes. Three videos go deeper.

Specs: the one thing you write. Seams: what the oracle controls, and
why a value it doesn't control reads unstable. And verdicts: the four answers, the block that
qualifies them, and how to declare the change you meant to make.

And that test we couldn't finish? We never had to know what checkout should return. The old code
already knew.
