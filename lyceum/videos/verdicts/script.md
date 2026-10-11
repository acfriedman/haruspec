---
title: "Verdicts: what a green proves"
status: draft 1
updated: 2026-10-11
# Written form → spoken form, applied only to the text sent to the voice.
pronounce: {}
# Subtitles: a track viewers turn on, or `captions: burned` to draw them into the picture.
# captions: burned
# The look: the dark canvas, or `theme: paper`, a light, formal look for presentations.
# theme: paper
# The files this video explains, one per line: `- path (what the video takes from it)`.
# `lyceum stale` watches them; `lyceum stale --mark verdicts` records the commit they were checked at.
sources:
  - Sources/Core/Verification.swift (resolve, where a divergence stands and an equivalent survives only over trusted coverage)
  - Sources/Core/Coverage.swift (the gap reasons, trustsEquivalent, a false equivalent as the one catastrophic outcome)
  - Sources/Core/Diff.swift (the diff only says equivalent or diverged; divergence kinds; intended versus collateral)
  - Sources/Spec/SpecVerdict.swift (stability applied above coverage, so disagreeing runs flip any verdict to unstable)
  - Sources/Spec/SpecTerminalReport.swift (the report's line order, divergence, failing order and counterexample lines)
  - Sources/Spec/Qualification.swift (the qualification block's fields and wording, not audited versus an empty list)
  - Sources/Spec/Exploration.swift (the explored line)
  - Sources/Spec/Stability.swift (three replays by default, the run-to-run delta, the baseline self-check)
  - Sources/Spec/UncontrolledSeam.swift (the uncontrolled seams line and its remedies)
  - Sources/Spec/SpecRunner.swift (a live red keeps every failing case, reports the richest, shrinks its order)
  - Sources/Spec/SpecPlanRuns.swift (a replay never shrinks)
  - Sources/Spec/FailingCases.swift (the most informative failing case)
  - Sources/CLI/main.swift (exit codes 0, 3, 4, 5 and 6, only 0 passes)
  - Sources/Core/Comparison.swift (what a comparison sets aside at diff time, gating defaults for domain moves and spawn edges)
  - Sources/Core/Intent.swift (classification, the verdict recomputed from the residual collateral)
  - Sources/Core/NarrowedIntentions.swift (Changes and its modifiers)
  - Sources/Core/IntentSuggestions.swift (the offered declaration, as narrow as the failing cases allow)
  - Sources/Local/LocalCheckOutcome.swift (the intent save offer, the exit code per spec)
  - Sources/Local/IntentDocument.swift (the intent file and its pull request block)
  - Sources/CLI/CheckCommand.swift (haruspec intent save)
  - Tests/SpecTests/Fixtures/diverged.result.json (the real qualification block and divergence on screen)
  - Tests/SpecTests/SpecVerdictSerializationTests.swift (the spec and the replay behind the fixture)
  - Tests/SpecTests/SpecPrototypeTests.swift (the rounding and truncating carts)
  - Tests/SpecTests/UnmatchedDomainTests.swift (the mistyped seam key, and what it reads today)
  - Tests/SpecTests/StabilityTests.swift (the coin-flip subject's unstable delta, the self-minting baseline)
  - Tests/CoreTests/DomainMigrationTests.swift (a moved domain's divergence and its declaration)
  - Tests/CoreTests/SpawnEdgeDiffTests.swift (a dropped synchronization's divergence)
  - Examples/checkout-comparison.json (the comparison on screen)
  - README.md (the verdict table, the intent save command)
  - docs/verdicts.md (the paired concept doc)
  - example-xcode-migration/docs/dogfood/local-check.md (the loyalty points red and green, 63 to 126)
---

<!--
Format: one `## NN · id — Title` per scene. `> Visual:` lines describe the animation; every other
paragraph is narration, spoken in order. The narration is the only text sent to TTS, so it is
written for the ear: no identifiers that read badly aloud, short sentences. The intent above the
first scene is never narrated.
-->

# Intent

- **Point:** a verdict is a claim about what was explored, not a color. A green proves only what
  its qualification block says it saw; every other verdict says what to do next; and the change you
  meant is declared, narrowly, rather than loosened out of the gate.
- **Angle:** start from a real false green (a mistyped seam key read EQUIVALENT over sixty-four
  identical inputs) and the asymmetry it exposes: a false equivalent is the one catastrophic
  outcome. Then build the verdict outward from the diff: two layers and the exit codes, the
  qualification block line by line, reading a red, the two abstentions (CANNOT-VERIFY, UNSTABLE),
  what a comparison sets aside versus what gates until declared, and intent. End where it began:
  that green reads CANNOT-VERIFY today.
- **Length:** about 5 minutes.
- **Notes:**
  - Real output only. The qualification block and divergence in scenes 3 and 4 are `report()`
    rendered from `Tests/SpecTests/Fixtures/diverged.result.json` by reading
    `SpecTerminalReport.swift`, `Qualification.swift`, `Exploration.swift` and `Stability.swift`.
    The README's "At a glance" is a trimmed version of that same artifact (it drops the
    `declared in:` line and the combined-variants clause); use the full rendering.
  - The fixture is a replay (three passes, order as recorded). Don't say its order was shrunk, and
    never say seam values are shrunk: only a live campaign check shrinks, and only the order.
  - Verdict names are caps on screen, lowercase in narration. Exit 6 is not a fifth verdict: it is
    an otherwise-green verdict whose declaration matched nothing, on the command line.
  - Stay out of the siblings: the how-to of injecting an uncontrolled seam is the seams video; how
    a spec is authored is the specs video. Point at them in a phrase.
  - Colours: baseline blue, candidate pink; EQUIVALENT green, DIVERGED red, CANNOT-VERIFY amber,
    UNSTABLE violet. Report cards in monospace, 22 to 26 px, left edge at 80 px.

## 01 · cold-open — A green that swept nothing

> Visual: Centre: a large green EQUIVALENT verdict pill. Under it, monospace at 30 px, the historical
> banner exactly as quoted in commit 90614a6's message (4 August 2026; today's report reads
> differently), with a small grey date stamp "August 2026" at its right:
> `EQUIVALENT  ·  64 runs · all 1 ordering x 64 seam variants  ·  coverage: 100%`
> On "almost nothing", the pill's green drains to grey. On "mistyped seam key", a code card slides
> in at the top right, titled "Tests/SpecTests/UnmatchedDomainTests.swift" (simplified: the test's
> key parameter written as the literal it is given, other ops elided):
> ```swift
> Op("add") { cart, seams in
>     cart.addItem(priceCents: 999, qty: Int(seams.int("qty", default: 2)))
> }
> .vary { Seam("qtyy", .int(1 ... 20)) }
> ```
> `"qty"` and `"qtyy"` get amber underlines; a dashed line between them ends in a small ✕. On "the
> same input", sixty-four small cassette tiles fan out under the banner, all one colour, and collapse
> into a single tile; "64 seam variants" in the banner gets an amber underline. On "quietly shrunk",
> "coverage: 100%" gets one too. On "costs you an hour", a balance appears along the bottom: the left
> pan "a false red: an hour" sits light. On "ships a bug", the right pan "a false green: a shipped bug"
> drops hard. On "one catastrophic outcome", the right pan's label rewrites to "a false EQUIVALENT".
> On "say what it saw", everything dims except the grey pill.

This is a real verdict Haruspec printed in August. Equivalent. Sixty-four runs, sixty-four seam
variants, and full coverage.

It meant almost nothing. The spec had a mistyped seam key, so nothing ever read it. All sixty-four
variants were the same input, and the coverage was measured over a surface that had quietly shrunk.

A red that's wrong costs you an hour. A green that's wrong ships a bug through a gate you trusted.
For an oracle, a false equivalent is the one catastrophic outcome. So a verdict has to say what it
saw.

## 02 · four-verdicts — Two answers, four verdicts

> Visual: Left third: two short trace strips, baseline blue on top, candidate pink below, both
> feeding a box labelled "diff". On "the traces matched, or they didn't", two pills leave the box: a
> green EQUIVALENT and a red DIVERGED. On "Two layers", two horizontal bands stack to the right of the
> box, labelled "coverage" and "stability". On "never hides a divergence", the DIVERGED pill passes
> straight through the coverage band, unchanged. On "becomes cannot verify", the EQUIVALENT pill
> enters the band and splits: one copy stays green with the caption "coverage stands behind it", the
> other turns into an amber CANNOT-VERIFY pill. On "any verdict becomes unstable", all three pills
> cross the stability band and a violet UNSTABLE pill forks off above them. On "exit code", a row of
> chips writes on along the bottom, one per number as it is spoken: "0 EQUIVALENT" (green),
> "3 DIVERGED" (red), "4 CANNOT-VERIFY" (amber), "5 UNSTABLE" (violet), then, set slightly apart,
> "6 declared, never observed" (grey, red outline). On "Only zero is a pass", chips 3 to 6 dim and
> chip 0 stays lit, with a small caption "Sources/CLI/main.swift".

Underneath, the diff can only say two things: the traces matched, or they didn't. Two layers above it
turn that into one of four verdicts.

Coverage first. It never hides a divergence. But an equivalent survives only when the coverage can
stand behind it. Otherwise it becomes cannot verify.

Then stability. If runs over identical inputs disagree, any verdict becomes unstable.

Each verdict has an exit code, so one command is the gate. Zero for equivalent, three for diverged,
four for cannot verify, five for unstable. And six for a declared change that never happened. Only
zero is a pass.

## 03 · qualification — What the block claims

> Visual: A report card fills the frame (80 px margins), titled
> "Tests/SpecTests/Fixtures/diverged.result.json · report()". Exact: `SpecVerdict.report()` rendered
> from the fixture: the README's promo-cart spec with ordering exploration on, recorded on the
> rounding cart and replayed against one that truncates. Monospace 22 px; the banner red; lines 2 to
> 8 bright, lines 9 to 13 dimmed until the next scene:
> ```text
> ❌ DIVERGED  promo-cart.artifact → promo-cart.artifact
>   explored: 385 runs · all 7 orderings × 55 seam variants
>   stability: 3/3 identical replays
>   coverage: 100% of 4 declared boundaries · domain-swept 0%
>   covered: PromoCart — 3 ops · 385 probes
>   declared in: PromoCart ← RoundBugCart (HaruspecSpecTests/SpecPrototypeTests.swift)
>   seams: coffeeQty (2 positions) · boundary edges 8 of 8 scheduled · 47 combined (every seam at once)
>   blind spots: not audited — capture completeness is unmeasured; effect channels outside the recorded seams may exist
>   2 divergence(s):
>     ≠ CheckoutCompleted: total: baseline=1798 candidate=1799
>     ≠ PromoCart.checkout: value: baseline=1798 candidate=1799
>   ↳ failing order: addCoffee → addCoffee → promo → promo → checkout
>   ↳ counterexample: coffeeQty=1,1
> ```
> A highlight bar steps down the block as each label is spoken. On "Explored", line 2; "385 runs",
> "all 7 orderings" and "55 seam variants" underline in turn on "almost four hundred runs", "all seven
> orderings" and "fifty-five sets of seam values". On "Stability", line 3. On "Coverage", line 4
> ("domain-swept 0%" stays dim). On "Covered", line 5; on "where they're declared", line 6. On
> "Seams", line 7, with "2 positions", "8 of 8 scheduled" and "47 combined" underlining in turn. On
> "blind spots", line 8. On "Not audited", the words "not audited" get a grey box. On "An empty
> list", a chip slides in under the card with the wording Qualification.swift renders for an audited,
> empty list: `blind spots: audited — no blind spots declared`.

That's why every verdict, green or red, carries a qualification block. This one is real, from the
engine's tests.

Explored: almost four hundred runs, all seven orderings, each with fifty-five sets of seam values.
Stability: three replays, all identical. Coverage: every declared boundary exercised. Covered: the
class and operations the claim is about, and where they're declared. Seams: each seam that varied,
how many readings it took, and how many boundary values ran.

And blind spots: what the capture couldn't see. Not audited means nobody looked. An empty list would
be a claim: someone looked, and found nothing.

## 04 · diverged — Reading a red

> Visual: The same card; lines 2 to 8 dim, lines 9 to 13 brighten. On "the checkout event's total",
> line 10 highlights, its "1798" turning baseline blue and "1799" candidate pink; on "checkout's
> return value", line 11 does the same. On "one cent higher", a small pink "+1¢" tag pins to both
> lines. On "truncates", a two-line code card slides in at the right, titled
> "Tests/SpecTests/SpecPrototypeTests.swift" (exact lines, one from each cart):
> ```swift
> let discount = promo ? Int((Double(subtotal) * 0.10).rounded()) : 0
> let discount = promo ? subtotal / 10 : 0 // BUG: truncates instead of rounding 10%
> ```
> the first line edged blue and tagged "GoodCart (baseline)", the second edged pink and tagged
> "RoundBugCart (candidate)". On "the failing order", line 12 highlights and its five labels lift
> into a row of chips above the card. On "counterexample", line 13 highlights and
> "coffeeQty=1,1" underlines. On "keeps every failing case", the card shrinks left and a grid of 385
> small squares fills the right, grey, with 36 of them turning red (the fixture's failing cases); on
> "the most informative one", one red square enlarges and links to line 10. On "shrinks the order", a
> separate illustrative chip row labelled "live campaign check" greys out chips one at a time, each
> drop checked against a small red "still diverges" tick (illustrative, no real shrink shown). On "the
> order it recorded", the row from line 12 returns with the caption "replay: as recorded".

Below the block, a red says what changed. Two divergences: the checkout event's total and checkout's
return value, each one cent higher in the candidate. The port truncates a discount the old code
rounded.

To reproduce it, the failing order: two adds, two promos, then checkout. And the counterexample:
the seam values that case read, a quantity of one, twice.

A red keeps every failing case and reports the most informative one. On a live campaign check, it
also shrinks the order, dropping operations while the divergence holds. A replay reports the order
it recorded.

## 05 · cannot-verify — When the oracle abstains

> Visual: An amber-bannered card, titled "Tests/SpecTests/UnmatchedDomainTests.swift · report()".
> Excerpt: lines rendered exactly by reading SpecTerminalReport.swift and Qualification.swift for the
> test's `unmatched.typo` spec against its refactored cart; the covered, declared-in and blind-spots
> lines are elided as "…":
> ```text
> ⚠️ CANNOT-VERIFY  unmatched.typo → unmatched.typo
>   explored: 1 run · all 1 ordering
>   coverage: 75% of 4 declared boundaries · domain-swept 0%
>     ⚠︎ declared domain matched nothing: qtyy (nothing read that seam)
>   …
>   seams: qtyy (declared, never read)
>   …
>   behavior matches across everything explored (0 divergences)
> ```
> On "the report names it", the ⚠︎ line highlights amber. On "Four gaps", the card slides up and four
> amber chips write on beneath it, one per clause: "unrecorded reach: the replay fell back to a live
> read" on "fell back to a live read"; "declared domain matched nothing" on "A declared seam nothing
> read"; "blind spot: NotificationCenter.default" on "the global notification center"; "no source
> found" on "couldn't read at all". On "only lowers the percentage", a fifth chip, grey and set apart:
> "unexercised: lowers the percentage, never gates". On "where to look", the card's `qtyy` and each
> chip's named boundary underline at once.

Cannot verify is the oracle declining to claim more than it saw. Here's that mistake today, and the
report names it: the declared domain matched nothing.

Four gaps take a green away. A replay that fell back to a live read, for an input the recording
never answered. A declared seam nothing read. An effect the source audit finds escaping capture,
like a post to the global notification center. And source the audit couldn't read at all.

A boundary the run just never reached only lowers the percentage. Each gap is named, so you know
where to look.

## 06 · unstable — When identical runs disagree

> Visual: Three horizontal replay lanes labelled "run 1", "run 2", "run 3", each fed by the same
> cassette icon at the left ("identical inputs"). On "every pass must agree", the lanes animate left
> to right in step. On "runs one and three diverged", lanes 1 and 3 end in red DIVERGED pills; on
> "run two matched", lane 2 ends in a green EQUIVALENT. On "whichever color it landed on", a single
> lane flickers red, green, red. On "the delta between runs", the three pills merge into a violet
> UNSTABLE pill and a card writes on beneath, titled "Tests/SpecTests/StabilityTests.swift · coin-flip
> subject". Excerpt: the banner and stability lines, rendered exactly by reading Stability.swift and
> UncontrolledSeam.swift (the test asserts the outcome lines); other lines elided:
> ```text
> 🌀 UNSTABLE  stability.subject → stability.subject
>   …
>   stability: 2 distinct outcomes across 3 replays of identical inputs:
>     runs 1,3 → diverged:
>       valueMismatch Total · value: baseline=42 candidate=43
>     run 2 → equivalent
>     ⚠︎ identical replays disagreed — an axis of nondeterminism is unmodeled (an uncontrolled seam, or a missing projection); the delta above points at it
>   uncontrolled seams — values the subject makes up itself:
>     Total.value (int): a value the subject makes up itself — inject its source through the initializer and supply it with `.provides`
> ```
> On "names the field that moved", the `Total.value (int)` line highlights violet. On "reruns the
> baseline against itself", the card slides left and a smaller card writes on at the right, titled
> "live campaign check: a baseline that mints its own identifier": two exact lines from the same test
> file's minting subject (the self-check's fingerprint lines between them, which carry random
> identifiers, elided as "…"):
> ```text
>   stability: the baseline disagreed with itself on the failing input:
>   …
>     Total.orderID (UUID): a fresh identifier — inject its source (a `() -> UUID` the initializer takes, supplied by the spec's `.provides`)
> ```
> On "The seams video", a small corner tag: "next: Seams".

Unstable means the same inputs gave different answers. A plan replays three times by default, and
every pass must agree, down to each divergence's values.

Here, runs one and three diverged, and run two matched. Without repetition, the gate would show
whichever color it landed on. Instead, the report shows the delta between runs, and names the field
that moved: a value the subject makes up for itself.

On a red, a live campaign check reruns the baseline against itself instead. A fresh identifier or a
clock reading usually turns up here. The seams video shows how to inject one.

## 07 · comparison — What counts as behavior

> Visual: Left half: a JSON card titled "Examples/checkout-comparison.json", exact:
> ```json
> {
>   "numericEpsilon": 0,
>   "timingBudgets": {
>     "CartService.checkout": 50
>   },
>   "unorderedGroups": [
>     ["CartDidChange", "AnalyticsDidTrack"]
>   ],
>   "ignoredKinds": []
> }
> ```
> As each item is spoken, a matching key glows: "numeric jitter" lights `numericEpsilon`, "a timing
> budget" lights `timingBudgets`, "either order" lights `unorderedGroups`; on "a noisy channel to
> ignore" and "per concurrency domain", two Swift chips write on under the card (spellings from
> Sources/Spec/Spec.swift and Sources/Core/Comparison.swift):
> `.ignore(notifications: ["AnalyticsDidTrack"])` and `Comparison(concurrency: .perDomain)`. Right half: two trace strips, baseline blue over candidate
> pink; in the candidate, `CartDidChange` and `AnalyticsDidTrack` are swapped. On "either order", a
> dashed bracket labelled "unordered group" closes over the pair and the swap's red mark fades. On "at
> diff time", the bracket becomes a translucent lens floating above the strips, which stay complete
> beneath it. On "can't excuse a value the subject makes up", a value cell in the candidate strip
> pulses violet with the label "uncontrolled seam", and the lens passes over it without dimming it.
> On "Concurrency changes go the other way", the right half clears to two lanes,
> "queue(serial):com.emporium.cart" and "actor:CartActor", and a `CartDidChange` event slides from the
> first to the second. Two red report lines write on below, one per cue (divergence details exact
> from Tests/CoreTests/DomainMigrationTests.swift and Tests/CoreTests/SpawnEdgeDiffTests.swift, each
> shown the way a report line renders a divergence). On "moved to another domain":
> ```text
> ≠ CartDidChange: ran on a different domain (queue(serial):com.emporium.cart → actor:CartActor#1)
> ```
> On "a synchronization the port dropped", an arrow from `Cart.checkout` to `Inventory.reserve`
> snaps, and:
> ```text
> ≠ Inventory.reserve: synchronization dropped: Cart.checkout → Inventory.reserve held in baseline (spawn edge from #0); the candidate leaves them concurrent
> ```
> On "until you say you meant it", a Swift chip writes on (exact, from DomainMigrationTests.swift)
> and the first red line turns grey:
> `Moves("CartDidChange", from: .queue("com.emporium.cart"), to: .actor("CartActor"))`.

Some differences aren't behavior. A spec declares them once, in its comparison: numeric jitter, a
timing budget, two independent notifications in either order, a noisy channel to ignore, or
comparison per concurrency domain.

It applies at diff time. The recorded traces stay complete; the comparison only changes how they're
read. And it can't excuse a value the subject makes up. That's an uncontrolled seam.

Concurrency changes go the other way. Work that moved to another domain, an ordering guarantee
relaxed, or a synchronization the port dropped: each gates by default, until you say you meant it.

## 08 · intent — Declaring the change you meant

> Visual: A terminal card writes on, the red line as logged in the example app's local-check dogfood
> (example-xcode-migration/docs/dogfood/local-check.md, scenario 3):
> `≠ LoyaltyPointsEarned: points: baseline=63 candidate=126`, with "63" blue and "126" pink, under a
> red DIVERGED banner. On "the command that declares it", the card's last lines write on, rendered
> by reading LocalCheckOutcome.swift's offer (simplified: the spec shown as `Cart`, the name an
> unnamed `Spec<Cart>` takes today; the 2026-09-22 log names it `cart.objc-to-swift`):
> ```text
> Cart: is this change the point of the branch? Declare it (edit it down to what you mean), then check again:
>     haruspec intent save Cart \
>       'Changes("LoyaltyPointsEarned", field: "points").increases().only(in: "checkout")'
> If you did not mean to change behavior, this is a regression: fix the code, don't declare it.
> ```
> On "the points field", "increasing" and "only in checkout", `field: "points"`, `.increases()` and
> `.only(in: "checkout")` underline in turn. On "your branch's intent file", a file card
> `.haruspec/intent/<branch>.md` slides in at the right, holding the section IntentDocument.swift
> writes on a save. Exact, except that its three HTML comment markers (begin, evidence and end, each
> naming the spec) are drawn as thin grey rules rather than spelled out:
> ````text
> ### `Cart`
>
> ```haruspec-intent Cart
> Changes("LoyaltyPointsEarned", field: "points").increases().only(in: "checkout")
> ```
>
> _Not yet checked with these declarations — run `haruspec check`._
> ````
> On "a pull request description carries", a pull request description frame appears behind the file
> card holding the same fenced block. On "gates on whatever is left", the terminal card's banner flips
> to a green EQUIVALENT and its body rewrites to (the report() wording; the count assumes the single
> divergence scenario 3 logged, and the line is as logged in scenario 4):
> `  1 divergence(s) — all intended, absorbed by declared intent:`
> `    ✓ intended LoyaltyPointsEarned: points: baseline=63 candidate=126`
> On "code six", the grey "6 declared, never observed" chip from scene 2 pulses once at the bottom. On
> "That August green", the scene 1 banner returns at the top, is struck through, and the scene 5
> CANNOT-VERIFY banner writes on beneath it. On "nothing more", the scene 3 qualification block fades
> in behind everything at low opacity and holds.

Which is what intent is for. A branch doubles loyalty points, and the check goes red: sixty-three
points before, a hundred and twenty-six after. The report ends with the command that declares it, as
narrow as the failing cases allow: the points field, increasing, only in checkout.

Run it, and the line lands in your branch's intent file, in the block a pull request description
carries. The next check absorbs that change, and gates on whatever is left. Green, and it still
shows what it absorbed. A declaration nothing matched fails with code six.

That August green would read cannot verify today. A verdict proves what its block says it saw, and
nothing more.
