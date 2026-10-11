# Verdicts and intent

Every check ends in one of four verdicts, and every verdict states what it was measured over. This page is about
reading them: what each verdict means and what to do next, the qualification block line by line, how a red points
at its cause, why a run abstains, and how to declare the change you meant so the check can tell it apart from the
ones you didn't. Writing the spec is [specs.md](specs.md); controlling what the subject reads is
[seams.md](seams.md).

## Why a green has to say what it saw

A wrong red costs an hour: you look, find nothing, and move on. A wrong green ships a bug through a gate you trusted.
The two errors are not symmetric, and for an oracle a false `EQUIVALENT` is the one catastrophic outcome. So a green
never stands on the diff alone.

The case that made this concrete: a spec declared `Seam("qtyy", .int(1 ... 20))` where the code read `"qty"`. It
printed `EQUIVALENT` over 64 seam variants at 100% coverage. Nothing had read the mistyped key, so all 64 variants
were the same input, and the coverage was measured over a surface that had quietly shrunk. The same mistake now reads
`CANNOT-VERIFY` and names the key ([below](#cannot-verify-coverage-gaps)).

## The four verdicts

| Verdict | Exit | What it means | What to do next |
| --- | --- | --- | --- |
| ✅ `EQUIVALENT` | 0 | Every probe matched under the declared comparison and intent, and the coverage stands behind it. | Read the qualification block: the green covers what it lists, and nothing else. |
| ❌ `DIVERGED` | 3 | Behavior differs. The report names each divergence, the failing order and the counterexample. | Fix the regression or, if the change is the point, [declare it](#intent-declaring-the-change-you-meant). |
| ⚠️ `CANNOT-VERIFY` | 4 | A match the oracle can't stand behind: a coverage gap is named. | Close the gap the report names. |
| 🌀 `UNSTABLE` | 5 | Runs over identical inputs disagreed. The report shows the delta between them. | Inject the value the delta names ([seams.md](seams.md)). |

Two more exit codes come from the command line. Exit 6 is an otherwise-green verdict whose declared intent matched
nothing ([below](#declared-but-not-observed)). Exit 1 means no verdict at all: a build or replay failed before one
existed. Only 0 passes. `haruspec check` and `haruspec report` exit with the worst code across their specs, so the
same command is the gate. In a campaign test, `check` throws unless the build earned the verdict it expects
(`expecting:` defaults to `.equivalent`).

The diff itself only ever says one of two things: the traces matched, or they didn't. Two layers above it decide the
verdict:

1. **Coverage.** A divergence always stands. An equivalent survives only when the coverage has no gating gap
   ([below](#cannot-verify-coverage-gaps)); otherwise it becomes `CANNOT-VERIFY`.
2. **Stability.** When repeated runs over identical inputs disagree, the verdict is `UNSTABLE`, whatever color the
   first run was.

## Reading the qualification block

Every verdict carries a qualification block: green, red or abstaining. This is the terminal report of the engine's
own fixture, `Tests/SpecTests/Fixtures/diverged.result.json`: the promo cart from the [README](../README.md) with
ordering exploration on, recorded against the implementation that rounds its discount and replayed against a port
that truncates it.

```text
❌ DIVERGED  promo-cart.artifact → promo-cart.artifact
  explored: 385 runs · all 7 orderings × 55 seam variants
  stability: 3/3 identical replays
  coverage: 100% of 4 declared boundaries · domain-swept 0%
  covered: PromoCart — 3 ops · 385 probes
  declared in: PromoCart ← RoundBugCart (HaruspecSpecTests/SpecPrototypeTests.swift)
  seams: coffeeQty (2 positions) · boundary edges 8 of 8 scheduled · 47 combined (every seam at once)
  blind spots: not audited — capture completeness is unmeasured; effect channels outside the recorded seams may exist
  2 divergence(s):
    ≠ CheckoutCompleted: total: baseline=1798 candidate=1799
    ≠ PromoCart.checkout: value: baseline=1798 candidate=1799
  ↳ failing order: addCoffee → addCoffee → promo → promo → checkout
  ↳ counterexample: coffeeQty=1,1
```

The first line is the verdict and the names of the two traces; on a spec run both carry the spec's name. Then:

- **explored**: the runs spent and how they split. `all 7 orderings` means every valid ordering ran; a sampled run
  reads like `50 of 2520 orderings (2%)`, with `≥` when the total is only a lower bound. `× 4 settle schedules`
  appears when the subject held work across the gaps between operations, `× 55 seam variants` is the sets of seam
  values per ordering, and `12 out-of-order` counts orderings that deliberately broke a declared `.after`.
- **stability**: how the verdict behaved when repeated. A replay (`verify(replaying:)`, and so every
  `haruspec check`) runs the plan three times: `3/3 identical replays`. A live campaign check runs once; on a red it
  reruns the baseline against itself on the failing input and says `the baseline reproduced itself on the failing
  input`. A single-run green prints no stability line, because one run can't disagree with itself.
- **coverage**: the share of declared boundaries the run exercised cleanly. Boundaries are the spec's operations and
  every seam the run read, plus any declared seam nothing read. `domain-swept` is the share exercised over a
  generated range of values rather than one recorded value; it is credited only when the verdict held across the
  sweep, so a red reads `0%`. Warning lines under it name the gaps that gate.
- **covered**: the classes the traces reached, the number of operations and the number of probes. The claim is
  scoped to these.
- **declared in**: where each covered label is declared, as `label ← symbol (file)`. These are the files the source
  audit reads.
- **seams**: each varied seam with how many readings it took (`2 positions`), `declared, never read` when nothing
  read it, and `derived default` when the engine chose its domain rather than you. Then the boundary values the
  schedule ran (`8 of 8 scheduled`, with how many were dropped for budget) and how many variants moved every seam at
  once.
- **properties**: present when the spec observes properties: the ones snapshot at the end of every capture, whose
  end-state values always gate.
- **blind spots**: what the capture could not see. `not audited` means no source audit ran, so nothing is claimed.
  `audited — no blind spots declared` is a claim: the audit read the subject's source and found no channel the
  capture misses. Otherwise the line lists channels, marked `(declared)` when the spec accepts one,
  `(declared, not found)` when an acceptance matched nothing, and `(no source found)` when the audit couldn't read a
  declaration's source.

The audit runs on every `haruspec check`, whenever `HARUSPEC_SOURCE_ROOT` is set for a test run, and when a test
asks for it. An empty list pinned in a test fails, naming the channel, the day a port reaches one:

```swift
let verdict = try await subject.check(SwiftCart.self).audited()
#expect(verdict.qualification.blindSpots == [])
```

The pull request comment (`haruspec report --markdown`) and the HTML report render the same entries, so a reviewer
and a developer read the same claim.

## Reading a divergence

Below the block, a red lists what changed, one divergence per line: the event's label, then where and how it
differed. `≠ CheckoutCompleted: total: baseline=1798 candidate=1799` says the `total` field of the
`CheckoutCompleted` notification was one cent higher in the candidate. A divergence is one of nine kinds: an event
missing from the candidate (`missingEvent`) or new in it (`unexpectedEvent`), a payload that differs field by field
(`valueMismatch`), an event that moved where order is compared (`reordered`), the four concurrency changes
[below](#structural-differences-gate-until-declared) (`domainMigration`, `orderingRelaxed`, `orderingLost`,
`orderingAdded`), and a signposted interval that grew past its timing budget (`timingRegression`). The terminal
report prints each as `≠ label: detail`; the markdown and HTML reports name the kind. Two lines then say how to
reproduce the failure:

- `↳ failing order` is the operations the failing case ran. Settle steps (`settle:ready`, `settle:elapsed`) appear
  where the case let held work land between operations. When the order broke a declared `.after`, an
  `⚠︎ out-of-order: breaks …` line follows: a finding on a path the spec says shouldn't happen, worth triaging as
  defensive code rather than a regression.
- `↳ counterexample` is the seam values that case read, one per reading: `coffeeQty=1,1` means both reads returned 1.

A red runs every probe, keeps every failing case, and reports the most informative one (a case whose new values are
something rather than zero or empty). What other failing cases found that the reported one doesn't show follows under
`also in other failing cases`, so one loud bug can't hide a quieter one. On a live campaign check (`check`,
`verify(candidate:)`) the reported case's order is then shrunk: operations are dropped one at a time while the
divergence still reproduces. The seam values are the case's own and are not shrunk. A replay never shrinks, because a
shorter order has no recorded golden to compare against, so it reports the order as recorded.

## Cannot verify: coverage gaps

`CANNOT-VERIFY` is the oracle declining to claim more than it saw. It downgrades an equivalent and never hides a
divergence. Four gaps trigger it:

| Gap | Where the report shows it | What it means |
| --- | --- | --- |
| Unrecorded reach | `⚠︎ unrecorded reach: <boundary> (replay fell back to live)` | the run asked for an input the recording never answered, or a recorded operation no longer exists, so the inputs were not held identical |
| Unmatched domain | `⚠︎ declared domain matched nothing: <seam> (nothing read that seam)` | a domain was declared for a key nothing read: usually a typo, sometimes a read on a branch the golden run never took |
| Bypassed channel | `blind spots: <channel>` | the source audit found the subject reaching a channel the capture can't see: `NotificationCenter.default`, `Timer / RunLoop`, `Combine`, `KVO`, `dispatch` or `Core Data` |
| Unreadable source | `blind spots: <symbol> (no source found)` | the audit couldn't find the source of a covered declaration, so it can't claim it saw every channel |

A declared boundary the run never reached doesn't gate: it only lowers the coverage percentage. The mistyped key from
the top of this page, today (the covered, declared-in and blind-spots lines elided):

```text
⚠️ CANNOT-VERIFY  unmatched.typo → unmatched.typo
  explored: 1 run · all 1 ordering
  coverage: 75% of 4 declared boundaries · domain-swept 0%
    ⚠︎ declared domain matched nothing: qtyy (nothing read that seam)
  seams: qtyy (declared, never read)
  behavior matches across everything explored (0 divergences)
```

Fix a mistyped key where it is declared. A channel the subject reaches around the capture is best injected
([seams.md](seams.md)); when every candidate shares it because it lives in the baseline's own code, the spec can
accept it by name instead, with `.accepts(uncaptured: "NotificationCenter.default")`. An accepted channel stops
gating and stays on every verdict as `NotificationCenter.default (declared)`. A channel only one port introduces is
accepted at that port's check site, with `Accepts(uncaptured:)` in its intent. Accepting one channel says nothing
about another.

## Unstable: reading the delta

`UNSTABLE` means the same inputs gave different answers, so neither answer can gate. A replay runs three passes, and
each must reach the same verdict with the same divergences, values included. When they don't, the report shows each
distinct outcome with the passes that produced it, and names the fields that moved. From the engine's stability
tests, a subject that answers differently on alternate captures:

```text
🌀 UNSTABLE  stability.subject → stability.subject
  …
  stability: 2 distinct outcomes across 3 replays of identical inputs:
    runs 1,3 → diverged:
      valueMismatch Total · value: baseline=42 candidate=43
    run 2 → equivalent
    ⚠︎ identical replays disagreed — an axis of nondeterminism is unmodeled (an uncontrolled seam, or a missing projection); the delta above points at it
  uncontrolled seams — values the subject makes up itself:
    Total.value (int): a value the subject makes up itself — inject its source through the initializer and supply it with `.provides`
```

A live campaign check measures the same thing where it matters: on a red, it reruns the baseline against itself on
the failing input. A baseline that can't reproduce itself makes the red `UNSTABLE` rather than a finding about the
candidate, with a line such as `Total.orderID (UUID): a fresh identifier — inject its source (…)`. A red that
reproduces exactly is a red; stability never softens it. Injecting the source the line names is
[seams.md](seams.md).

## Comparison: what isn't behavior

A comparison declares the differences that aren't behavior. It belongs to the spec, so every candidate is compared
the same way, and it defaults to strict: everything left after capture is behavior.

| Field | Sets aside |
| --- | --- |
| `numericEpsilon` | numeric differences up to this absolute amount |
| `timingBudgets` | per label, how much a signposted interval may grow before it is a timing regression |
| `unorderedGroups` | reorderings confined to a group of labels, such as two independent notifications |
| `ignoredKinds` | every event of these kinds |
| `ignoredNotificationNames` | notifications with these names, the channel `.ignore(notifications:)` opts out |
| `concurrency: .perDomain` | scheduler interleaving: an ordered domain (main, an actor, a serial queue) is compared as a sequence, an unordered one (a concurrent queue, ambient work) as a multiset, and order across domains is dropped |
| `structuralComparison` | the auto-captured structural tier: `.advisory` reports its divergences without gating, `.ignored` drops it |

```swift
Spec<Cart> {
    Amend("checkout").last()
}
.comparing(Comparison(concurrency: .perDomain))
.ignore(notifications: ["AnalyticsDidTrack"])
```

`.comparing` replaces the whole comparison, so call `.ignore(notifications:)` after it. A comparison also loads from
JSON (`Comparison(contentsOf:)`, or `haruspec diff --comparison`), as in
[Examples/checkout-comparison.json](../Examples/checkout-comparison.json).

A comparison applies at diff time. The recorded traces stay complete, and reports still show every event; the
comparison only changes how two traces are read. It has no way to set aside a value the subject makes up itself (a
fresh identifier, a clock reading). That is an uncontrolled seam, which reads `UNSTABLE` until it is injected, and a
comparison file carrying the retired `volatileFields` key fails to load and says so.

## Structural differences gate until declared

Concurrency changes run the other way: they are behavior, and they gate by default.

| Change | The report says | Declare it with |
| --- | --- | --- |
| work moved to another domain | `ran on a different domain (queue(serial):com.emporium.cart → actor:CartActor#1)` | `Moves("CartDidChange", from: .queue("com.emporium.cart"), to: .actor("CartActor"))` |
| an ordered domain's guarantee dropped (under `.perDomain`) | `ordering guarantee dropped: …` | `Relaxes(orderingOf: .queue("com.emporium.cart"))` |
| a synchronization the baseline held, dropped | `synchronization dropped: Cart.checkout → Inventory.reserve held in baseline (spawn edge from #0); the candidate leaves them concurrent` | `Drops(synchronizationOf: "Inventory.reserve")` |
| a new synchronization, such as awaiting fire-and-forget work | `synchronization added: …` | `Awaits("Inventory.reserve")` |

Declaring a move excuses the move, never the values carried across it: a changed value on a moved event still gates.
A comparison can turn `domainMigration` or `spawnEdges` down to `.advisory` (reported, not gating), but the usual
move is to declare the change at the check site of the port that makes it ([below](#where-intent-is-declared)): a
serial queue that became an actor is `Moves(everythingFrom: .queue("SerialQueue"), to: .actor(SwiftCartActor.self))`.

## Intent: declaring the change you meant

With nothing declared, every divergence gates: parity. When a change is the point, declare it. A divergence a
declaration matches becomes intended: it is reported (`✓ intended` in the terminal) and doesn't gate. The verdict is
then recomputed from what is left, the collateral, so the change you meant goes green and anything else you changed
still fails. A green by declaration still shows what it absorbed, and the markdown report lists where each
declaration was first observed.

### The vocabulary

Each declaration names one kind of divergence. Modifiers narrow what it absorbs.

| Declaration | Absorbs | Modifiers |
| --- | --- | --- |
| `Changes("Receipt", field: "discountCents")` | a changed value in that field (no field: any field of the event) | `.to(_:)`, `.increases()`, `.decreases()`, `.within(_:)`, `.when(_:is:)`, `.only(in:)` |
| `Emits("LoyaltyPointsEarned")` | a new event | `.when(_:is:)`, `.only(in:)`, `.once(per:)`, `.after(_:)`, `.before(_:)` |
| `Omits("Inventory.reserve")` | a removed event | the same as `Emits` |
| `Reorders("Archive.archive", before: "CartDidChange")` | a reordered event, optionally in a direction | |
| `Moves("Cart.add", from: .ambient, to: .actor("SwiftCartActor"))` | a domain move; `Moves(everythingFrom:to:)` for a whole domain | `.only(in:)` |
| `Relaxes(orderingOf:)`, `Drops(synchronizationOf:)`, `Awaits(_:)` | the structural changes above | |
| `Accepts(uncaptured: "Combine")` | a blind spot the audit found, kept on the verdict | |

A timing regression has no declaration: it is always collateral. Declaring one field never excuses another field of
the same event, and each declaration takes at most one value relation and one operation scope.

### Keep declarations narrow

A declaration is a standing excuse: it absorbs every divergence it matches, including ones that arrive later. So
make it say what the change does, not only where. In the example app, a feature doubled loyalty points when a promo
applied. Under a bare `Changes("LoyaltyPointsEarned", field: "points")`, a one-character slip that halved those
points instead still read green; with `.increases()` the same slip went red, while the real feature stayed
absorbed. A divergence a declaration names but whose modifier rejects stays collateral, and the markdown report
names the declaration that rejected it rather than offering a wider one.

A red offers the narrowest line its failing cases prove: `.to(value)` when every case showed one value,
`.increases()` or `.decreases()` when they all moved one way, `.within(low ... high)` otherwise, scoped
`.only(in:)` when every case shares an operation. Edit it down to what you mean, and widen it only on purpose.

### Where intent is declared

**In a test, at the check site.** Intent belongs to the build that makes the change, never to the spec, so one port's
excuses can't leak to another:

```swift
try await subject.check(
    SwiftCart.self,
    declaring: Intent {
        Changes("LoyaltyPointsEarned", field: "points").increases().only(in: "checkout")
    }
)
```

**On your branch, for `haruspec check`.** A red check ends with the command that would declare it:

```bash
haruspec intent save Cart \
  'Changes("LoyaltyPointsEarned", field: "points").increases().only(in: "checkout")'
```

`intent save` validates each line with the gate's grammar and writes the spec's section of
`.haruspec/intent/<branch>.md` (`--replace` replaces the section's lines; `haruspec intent remove Cart` drops it):

````markdown
<!-- haruspec:begin Cart -->
### `Cart`

```haruspec-intent Cart
Changes("LoyaltyPointsEarned", field: "points").increases().only(in: "checkout")
```

<!-- haruspec:evidence Cart -->
_Not yet checked with these declarations — run `haruspec check`._
<!-- haruspec:end Cart -->
````

The next `haruspec check` replays under these declarations and replaces the evidence placeholder with its verdict:
the commits compared, what each declaration absorbed, and the qualification block. Prose you add outside the
sections is never rewritten. Commit the file or ignore it; that is the team's call. Agents get the same two steps as
the `check` and `save_intent` tools of `haruspec mcp`.

**In a pull request description.** The intent file is in the pull request description format: one
`haruspec-intent <spec>` fenced block per spec, one declaration per line, blank lines and `//` comments skipped.
Pasting it into the description declares the same intent to a continuous integration gate, which resolves it with
`haruspec intent --body`. A line that doesn't parse fails loudly rather than becoming parity, and a second block for
the same spec is refused.

### Declared but not observed

A declaration that matched nothing anywhere in the run is either a feature that never switched on or intent left over
from an earlier revision, and either way an excuse waiting for a future divergence. The report names it under
`⚠︎ declared but not observed`, and on the command line an otherwise-green verdict exits 6. Remove the line, or make
the change produce what it declares. (A red makes no such claim: the run that failed may not have reached the case
the declaration was about.)
