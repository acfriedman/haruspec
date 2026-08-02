# Haruspec — the behavioral-oracle engine

A verification instrument for AI coding agents working on iOS/Swift. It captures **ground-truth
behavior** of running code (call/return sequences, side-effect notifications, state changes, timed
intervals) and lets you **prove behavioral equivalence** before/after a change — instead of trusting
"it compiles, looks right, tests pass."

It works in two modes on the same engine: **parity** (migrations, refactors — prove *nothing*
changed) and **extension** (features — surface *what* changed and separate the intended delta from
collateral regressions riding along). Migration is the special case where the intended change is
empty.

The oracle engine is the core capability; migrations and refactors are applications that call it.

> **Status: validation-gate spike.** This slice implements and proves the hard core — trace
> capture → store/reload → *deterministic* behavioral diff with declared tolerances — on a real
> module. It settles the canonicalization problem first, built as a reusable engine rather than a
> one-off.

**Docs:** durable design and the interceptable-seam catalog live in [`docs/`](docs/README.md).

---

## The behavioral-diff primitive

Everything is a caller of one reusable capability:

1. **Capture** — instrumented code records a structured trace of observable behavior.
2. **Canonicalize** — remove nondeterminism (pointers → symbolic ids, OS threads → logical threads,
   wall time → a logical clock, volatile values → redacted) so two runs are comparable.
3. **Transform** — an agent (or a human) changes the code.
4. **Replay + Diff** — re-run the same spec, capture the new trace, and diff within declared
   tolerances. The pass/fail oracle is *"new behavior matches old,"* not *"compiles."*

## Architecture (engine first, applications second)

| Module        | Role |
|---------------|------|
| `HaruspecCore`  | The evergreen primitive: trace model, canonicalization, tolerance spec, and the LCS-based behavioral diff. Pure, dependency-free, fully unit-tested. |
| `HaruspecTrace` | The runtime capture library: the `TraceRecorder` (call/ret/stateChange/signpost, thread-safe, injectable clock), the ambient `TraceContext`, zero-code backends — `NotificationInterceptor` records `NotificationCenter` posts, `KVOInterceptor` records observed property changes — and a `Codable → CanonicalValue` bridge for automatic value capture. |
| `HaruspecMacros` | The opt-in `@Traced` / `@TracedMethod` macros for zero-code method capture. Backed by `HaruspecMacroPlugin` (the only SwiftSyntax user); kept out of the engine core. |
| `HaruspecSeams` | The record/replay **seam** library: the `Cassette` primitive (record once, replay into both branches, misses surfaced not fabricated) plus injected seams — clock, RNG, `UserDefaults`, `URLSession` (via `URLProtocol`, no swizzle), locale/timezone, keychain, file I/O — and `HaruspecSeam`, the ambient provider the `@Seamed` macro rewrites bare `Date()`/`UUID()` into (DEBUG-only) to reach un-injected legacy code. Depends only on `HaruspecCore`. See [`SEAMS.md`](docs/SEAMS.md). |
| `HaruspecDemo`  | A sample application: a checkout module in four variants — baseline, a behavior-preserving refactor, a subtly-buggy version, and a *feature* change (loyalty points) that also carries a collateral regression — that exercises the engine end-to-end. |
| `haruspec`    | A thin CLI: `diff`, `demo`, `canonicalize`. |

No Swift-6-specific (or migration-specific) logic lives in the core — applications configure the
engine via a `Tolerance`.

## Capture layers (toward zero-code adoption)

The goal is that a team turns the oracle on rather than hand-instrumenting for it. Capture is layered:

- **`@Traced` method capture (live, zero-code).** `@attached(body)` macros wrap every method of a
  `@Traced` class to record call/args/return against the ambient recorder — no recorder property, no
  per-method code. A stable label (`@Traced("CartService")`) keeps the trace comparable across a type
  rename. The demo's services carry *zero* `recorder.*` calls.
- **Timing, baked in.** Mark a method `@Timed` (or a whole type with `@Traced(timing: true)`) and the
  macro records the method's duration as a signpost interval — no hand-written timing region. For a
  *sub-region* of a method (finer than a whole method, which a macro can't express) use
  `Haruspec.interval`.
- **Runtime interception (live, zero-code).** `NotificationInterceptor` observes a `NotificationCenter`
  and records every product notification during a capture window — the demo services post ordinary
  notifications with no oracle awareness. `KVOInterceptor` does the same for observed properties.
- **Automatic value capture (live).** Arguments and return values ride the `Codable → CanonicalValue`
  bridge, so most payloads need no hand-written conversion.
- **Temporal markers + two tiers (live).** The **structural** tier is internal call mechanics
  (`@Traced` calls/returns, timing) — named after code symbols, so it drifts under renames. The
  **semantic** tier is observable product behavior — notifications, KVO/state changes, and payload-free
  `Haruspec.marker("checkout_completed")` signposts — named after domain concepts, so it survives
  refactors. Markers carry *no payload* on purpose: values are verified through production seams
  (notification userInfo, return values), never through instrumentation you authored ("don't test the
  test code"). `structuralComparison` chooses which tier gates: `strict` (default — the whole trace is
  the contract, ideal for mechanical migrations), `advisory` (structural divergences reported but don't
  fail), or `ignored` (only the semantic tier gates). See "Two tiers" below.

## The tolerance model

The declared "acceptable behavioral delta" — a JSON contract (see
[`Examples/checkout-tolerances.json`](Examples/checkout-tolerances.json)):

- `volatileFields` — payload keys ignored as inherently non-deterministic (UUIDs, timestamps).
- `numericEpsilon` — absorbs floating-point jitter.
- `timingBudgets` — per-interval allowed slowdown; a regression beyond it is flagged.
- `unorderedGroups` — labels whose relative order isn't significant (independent side effects).
- `ignoredKinds` — event kinds dropped entirely (noisy internal telemetry).
- `structuralComparison` — `strict` (default) / `advisory` / `ignored`; how the structural tier gates
  the verdict (see below).

Anything not explicitly tolerated is a divergence.

## Two tiers: surviving renames

The **structural** tier is internal call mechanics (`CartService.checkout` calls/returns, timing),
named after code symbols — so a refactor that renames or restructures makes it diverge even when
behavior is unchanged. The **semantic** tier is observable product behavior — the notifications the app
posts, KVO changes, and payload-free markers — named after domain concepts, so it's the durable
contract. `structuralComparison` picks which tier gates:

| Mode | Structural divergences | Use for |
|------|------------------------|---------|
| `strict` (default) | fail the verdict | Mechanical migrations (Swift 6) — nothing renames, so full coverage is free. |
| `advisory` | reported, don't fail | Refactors where you want the structural signal but gate on the semantic tier. |
| `ignored` | dropped entirely | Rename-heavy refactors (e.g. imperative → reactive) — only the semantic tier is compared. |

In the demo, ignoring the structural tier still catches the regression: the `CheckoutDidComplete`
notification carries the wrong `totalCents`, and the buggy `removeItem` drops its `CartDidChange`. Even
with every code-symbol event discarded, the observable-behavior contract holds the line — the
payload-free `checkout_completed` marker just pins the milestone's place in the sequence. That
ordering-survives-the-churn property is exactly what an imperative → reactive migration needs, where
the call graph reshuffles but the temporal coupling of product milestones must not.

## Parity vs. extension mode

The same engine serves two uses, and migration is the special case. A **`Tolerance`** says which
deltas *don't matter*; an **`Intent`** (its symmetric complement) says which deltas were *meant to
happen*:

- **Parity mode** (migrations, refactors) — `Intent.none`. Any divergence gates. "Prove nothing
  changed."
- **Extension mode** (features) — a populated intent spec. Divergences it declared
  (`expectedNewEvents` / `expectedRemovedEvents` / `expectedValueChanges`) are relabeled `intended`
  and don't gate; whatever's left is `collateral` — an *undeclared* change, the suspected regression.
  The verdict gates on residual collateral, not on divergence-existence.

Intent is *field-specific* — declaring `CheckoutDidComplete.pointsEarned` may change does **not** excuse
an undeclared `totalCents` change on the same notification, so you can't hide a regression behind a
broad declaration. The `CartServiceV3` variant demonstrates it: a loyalty-points feature (a new
`LoyaltyPointsEarned` notification and a `pointsEarned` field on `CheckoutDidComplete` — two intended
deltas) that also drops a `CartDidChange` notification (one collateral regression) — the oracle absorbs
the former and catches the latter. Both intended deltas live on production notifications, not on
instrumentation.

## Try it

```bash
swift test          # 166 tests: diff primitive, seam harness, coverage, property gen, plan replay, MCP
swift run haruspec demo   # capture baseline/refactor/regression, print both verdicts
swift run haruspec mcp    # serve verify_behavioral_parity + canonicalize_trace as MCP tools (stdio)
swift run haruspec report result.json --markdown   # render a replay verdict for a PR; exit = the CI gate
```

Agents get the same verdict as tools: `haruspec mcp` speaks MCP over stdio, and this repo's
`.mcp.json` registers it for Claude Code (`swift build` once so `.build/debug/haruspec` exists).

`haruspec demo` writes three traces and prints:

```
── Refactor (expected: EQUIVALENT) ──
✅ EQUIVALENT  checkout.baseline → checkout.refactor
  behavior trace matches within declared tolerances (0 divergences)

── Regression (expected: DIVERGED) ──
❌ DIVERGED  checkout.baseline → checkout.regression
  5 divergence(s):
    − missingEvent   CartDidChange          notification present in baseline, absent in candidate
    ⏱ timingRegression CartService.recompute duration 100→250 ticks exceeds budget +50 (Δ=150)
    ≠ valueMismatch  CheckoutDidComplete    totalCents: baseline=2525 candidate=2526
    ≠ valueMismatch  CartService.checkout   discountCents: baseline=260 candidate=259
    ≠ valueMismatch  CartService.checkout   totalCents: baseline=2525 candidate=2526
```

The "buggy" variant compiles and reads fine; a cursory review would pass it. Its three planted
regressions — an off-by-one from integer-division rounding, a dropped notification, and a blown
timing budget — are each caught and localized by the trace, not by tests.

### Using it from an Xcode app

Add the package (local path or git) and link the single **`Haruspec`** product — one
`import Haruspec` surfaces capture, macros, seams, and the Spec DSL. The macro plugin builds
as a macOS *host tool* automatically; SwiftSyntax never enters your app's link. One footgun:
build with `-destination 'platform=iOS Simulator,…'` and **never pass `-sdk iphonesimulator…`
to `xcodebuild`** — `-sdk` overrides `SDKROOT` for every target in the graph including the macro
host tool, which then gets planned for the simulator and fails every macro expansion with
*"produced malformed response."* (The dogfood app, `example-xcode-migration`, is the working
reference.)

Diff two saved traces directly:

```bash
swift run haruspec diff baseline.json candidate.json --tolerance Examples/checkout-tolerances.json
# exit 0 = equivalent, 3 = diverged  (CI-friendly)
```

Extension mode — declare the intended feature changes and gate only on collateral ones, with a relay
guide for a consuming agent:

```bash
swift run haruspec diff baseline.json feature.json \
  --tolerance Examples/checkout-tolerances.json \
  --intent Examples/checkout-intent.json \
  --agent
# intended deltas are absorbed; an undeclared change still exits 3
```

## Why this proves the thesis

The `testCaptureIsDeterministicUnderTolerances` test captures the *same* code twice: raw traces
differ (fresh UUID + timestamp every run), but under the tolerance spec they are **equivalent**.
That is the make-or-break canonicalization question — answered in the affirmative, with a real (if
small) module.

## Not yet built (deferred)

Characterization-test generation, simulator/XCUITest accessibility-tree capture, `xcresult`/MetricKit
ingestion for crash-repro, and the Swift-6 module ratchet — all future callers of this same engine.
(The MCP tool wrapper has since shipped — see `haruspec mcp` above.)

The other major track is **killing the feedback loop** so verdicts land in seconds on CI: a
record-and-replay **seam harness** (record the dependency boundary once, replay the same transcript
into both branches, diff the outputs) with **tiered isolation** — logic slice (pure Swift, no
simulator) → module cut → sim fallback — and a three-tier verdict (`EQUIVALENT` / `DIVERGED` /
`CANNOT-VERIFY`) that abstains rather than emit a false equivalent. The `Cassette` primitive and seven
injected seams (`HaruspecSeams`) record and replay, are wired to the diff engine end-to-end, and reach
un-injected call-sites — `@Seamed` for bare `Date()`/`UUID()`, and the **injectability precondition** (a
one-file settable-`.shared`-behind-a-protocol refactor, certified once by a swizzle bootstrap, then pure
DI) for legacy singletons; a cassette's misses feed the coverage that downgrades to `CANNOT-VERIFY`. The next depth step is **property-based generation at the
seam** — breadth beyond the single recorded path. See [`ROADMAP.md`](docs/ROADMAP.md) and the
interceptable-seam catalog in [`SEAMS.md`](docs/SEAMS.md).
