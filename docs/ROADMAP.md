# Roadmap

Feature roadmap for Haruspec, the behavioral-oracle engine. The north star: per commit, on CI, in seconds,
without touching production code, decide whether a change alters behavior — with a verdict that is
**sound** (never a false "equivalent"), **localized**, **coverage-reported**, and **honest** (abstains
when it can't faithfully isolate the change). Engine first, applications second — everything below is
either the engine, the isolation layer that lets it run cheaply, or a caller of it.

Status: ✅ shipped · 🔨 in progress · ⏳ next · 📋 backlog · 🔬 open research

Known constraints of *shipped* code (as opposed to unbuilt features) live in
[`LIMITATIONS.md`](LIMITATIONS.md).

---

## Engine — the behavioral-diff primitive

- ✅ **Trace model + canonicalization** — logical clock, symbolic object identity, logical threads,
  volatile-field redaction. (`HaruspecCore`)
- ✅ **Behavioral diff v0** — LCS alignment; missing/unexpected/reordered/value/timing divergences;
  declared tolerances (volatile fields, numeric epsilon, timing budgets, unordered groups, ignored
  kinds). The crown jewel.
- ✅ **Capture → store → reload** — deterministic JSON trace bundles.
- ✅ **Validation gate proven** — repeat captures of one real module verify EQUIVALENT under
  tolerances despite nondeterminism; a plausible-but-wrong change is caught and localized.
- ✅ **Three-tier verdict + coverage** — beyond `EQUIVALENT` / `DIVERGED`, `CANNOT-VERIFY`: the
  engine abstains (loudly) when a change crosses a seam it can't faithfully isolate, and reports the
  fraction of the change's behavioral surface actually exercised. Sound by design — a false
  `EQUIVALENT` is the one catastrophic outcome, so uncovered surface downgrades the verdict rather
  than being assumed equivalent. *Landed:* `TraceDiff.Verdict` gains `.cannotVerify`; a new
  `VerificationResult` (`HaruspecCore`) wraps the pure diff with a seam-agnostic `Coverage`
  (declared/exercised/gaps + fraction) and carries the *resolved* verdict. The pure `BehavioralDiff.compare`
  is untouched — it still only emits equivalent/diverged; `VerificationResult.resolve` is the only place
  `CANNOT-VERIFY` is reached, downgrading an EQUIVALENT it can't stand behind (DIVERGED always stands).
  The **first coverage source is the cassette**: `Cassette.coverage(declaring:)` (`HaruspecSeams`) turns
  `SeamMiss`es into `.unrecorded` gaps (live-fallback = isolation broke = hard downgrade) and the
  recorded/exercised tracks into the covered surface; the declared seam registry is the coverage map
  (defaults to the golden's recorded seams). Proven end-to-end (`SeamCoverageTests`): a change that
  reaches an *unrecorded* boundary whose value is coincidentally benign diffs `EQUIVALENT` on the trace
  alone — a false pass — but coverage catches the boundary and the oracle returns `CANNOT-VERIFY`. CLI
  exit code `4 = cannot-verify` (CI treats 3 and 4 as non-pass; only 0 is green). Deferred by decision:
  a numeric coverage *threshold* (declared `CoveragePolicy`) and **static seam-crossing analysis** to
  see boundaries no one recorded — today's denominator is honest but partial.
- ✅ **Expected-change (intent) spec** — `IntentSpec`, symmetric to `ToleranceSpec`: tolerances declare
  deltas that *don't matter*, the intent spec declares deltas that were *meant to happen*
  (`expectedNewEvents` / `expectedRemovedEvents` / `expectedValueChanges`). `TraceDiff.classified(against:)`
  reclassifies declared divergences `intended` and re-derives the verdict from the residual collateral —
  so extension mode (features) and parity mode (migrations) are the same engine, with migration the
  special case where intent = ∅ (`IntentSpec.none`). Field-specific: declaring one field of an event
  doesn't excuse a change to another.
- ✅ **Per-divergence labeling + agent relay** — each divergence tagged `intended` / `collateral`
  (`tolerated` deltas never become divergences); `haruspec diff --intent` gates only on collateral, and
  `--agent` prints a prompt-injected guide teaching a consuming agent how to relay the verdict.
  Demonstrated end-to-end by `CartServiceV3` (a loyalty feature carrying a collateral dropped
  notification).
- ⏳ **Richer narration + surprise score** — LLM-authored per-divergence explanations (what changed,
  where it originates, whether it's plausibly the feature) and a ranked surprise score, beyond the
  current deterministic labels + relay guide.
- 🔬 **Temporal-coupling assertions over markers** — beyond positional diffing, a happens-before /
  partial-order contract on the semantic marker sequence ("A precedes B regardless of what's inserted
  between them"), so ordering survives heavy imperative → reactive churn where the call graph
  reshuffles but milestone order must not. When structure is ignored, marker order *is* the contract.
  Ties into partial-order canonicalization (open research below).

## Capture — toward zero-code adoption

- ✅ **Runtime interception** — `NotificationInterceptor` (auto-captures `NotificationCenter` posts),
  `KVOInterceptor` (observed property changes). No service-side code.
- ✅ **Collaborator spying (silent side effects)** — `CollaboratorSpy` (`HaruspecTrace`) closes the blind
  spot where a SUT hands work to a singleton/collaborator that mutates the world but emits *no* other
  signal (no notification, no KVO). `.spy(on: Ledger.self)` on a `Scenario` intercepts every
  ObjC-dispatched instance method of a declared class and records each outbound call as a semantic-tier
  `effect` event (`Class.selector` + canonicalized args) into the ambient recorder, before invoking the
  original. A port that *drops* the call now diverges as a `missingEvent`; one that *alters an argument*
  as a `valueMismatch` — over the covered surface. Capture-all within the boundary by default, with a
  selector-level opt-out (`.spy(on:excluding:)`, the boundary-scoped analog of `.ignore(notifications:)`).
  Generic interception is a `forwardInvocation:` trampoline in a tiny first-party ObjC target
  (`HaruspecObjCShim`) — `NSInvocation` is unavailable in Swift, which is why the arg-reading lives there;
  it's the arg-reading sibling of `SeamSwizzle.exchange`. Proven in `CollaboratorSpyTests` (the `swift test`
  analog of the dogfood `silentSideEffectDropIsMissed` repro), including the without-spy false EQUIVALENT.
  Boundary (see LIMITATIONS): reaches only ObjC-dispatched methods; a pure-Swift `static`/`final` singleton
  needs `@Traced`/`@TracedForwarder`/DI. *Next (tier 3, deferred):* static seam-crossing analysis to
  abstain (`CANNOT-VERIFY`) when the SUT reaches an *undeclared* boundary the spy doesn't cover.
- ✅ **Automatic value capture** — `Codable → CanonicalValue` bridge; `RuntimeValue` for type-erased
  runtime values.
- ✅ **`@Traced` / `@TracedMethod` macros** — zero-code method call/args/return capture against an
  ambient recorder; stable labels across renames; SwiftSyntax confined to the opt-in macro path.
- ✅ **`@Timed` / `@Traced(timing:)`** — method-level timing baked into the macro; `Haruspec.interval`
  for sub-method regions.
- ✅ **Semantic tier + two-tier durability** — the durable contract is *observable product behavior*:
  notifications, KVO/state changes, and payload-free `Haruspec.marker(...)` temporal signposts. The
  fragile structural tier is internal call mechanics (calls/returns/timing). `structuralComparison:
  strict | advisory | ignored` chooses which gates, so rename-heavy refactors (imperative → reactive)
  gate on the durable tier while mechanical migrations keep structural at full coverage. Markers carry
  no payload — value verification rides production seams (notification userInfo, return values, KVO),
  never hand-authored instrumentation ("don't test the test code").
- 📋 **Lifecycle markers (free semantic tier)** — harvest framework lifecycle as durable,
  domain-labeled markers the developer gets almost for free: `@TracedScreen("checkout")` (UIKit — inject
  `viewDidAppear`/`viewDidDisappear`) and a `.tracedScreen("checkout")` view modifier (SwiftUI —
  `onAppear`/`onDisappear`), plus scene phase (`applicationDidBecomeActive` ↔ `scenePhase == .active`).
  Both sides emit the *same* stable marker (`checkout.appeared`), so a UIKit → SwiftUI migration verifies
  EQUIVALENT — the thesis in one screen. Two hard rules: (1) the label is a **stable domain name, not the
  type name** — `CheckoutViewController` → `CheckoutView` would otherwise reintroduce rename drift; (2)
  target appearance + scene phase only — `viewDidLoad`/`init` are structural (no SwiftUI equivalent).
  **Gated by the happens-before work above**: `onAppear` ≠ `viewDidAppear` (repeats, off-screen, lazy
  containers), so appearance markers need partial-order / de-dup comparison, not exact counts — else it
  cries wolf on every migration. Doubles as the capture substrate for the UI configuration-sweep
  application.
- ⏳ **Characterization-test generation** — from captured traces, emit runnable XCTest cases pinning
  current behavior (Feathers-style) for legacy code that has no tests.
- 📋 **Async / actor capture end-to-end** — body macro emits `await`, but async ordering across
  suspension points / thread hops needs the canonicalization work below.
- 📋 **`mutating` / struct-method capture**, selective opt-out (`@Untraced`).
- 📋 **Deeper capture backends** — Combine publishers, `os_signpost`/`OSLogStore` ingestion,
  lldb Python scripting for un-annotatable (system/third-party) code, and **harvesting the app's existing
  analytics / product-event stream** as free semantic markers: it's already domain-named *at* the
  milestones and survives every migration (the product layer doesn't move when the code does), so
  intercepting it — the way `NotificationInterceptor` does — yields a milestone skeleton with zero
  annotation.

## Isolation & headless replay — killing the feedback loop

The blocker to "seconds, on every commit" isn't the diff — it's getting the changed code *running*
without a cold app build, a simulator round-trip, and manual navigation through auth gates and nested
UI. The answer is **record the seam, don't mock the world**: capture the dependency boundary once from
the golden branch, replay the *same* transcript into both branches, and diff. See
[`SEAMS.md`](SEAMS.md) for the interceptable-seam catalog this depends on.

- 🔨 **Record-and-replay seam harness** — the core new primitive. Recorded transcripts (not
  synthesized mocks) drive the changed unit headlessly; both branches replay the same cassette so any
  divergence is attributable to the code. Unrecorded interactions surface as a signal, never fabricate.
  *Landed:* the `Cassette` primitive (record-once → replay-into-both, JSON-serializable, misses surfaced
  not fabricated) in the `HaruspecSeams` target, plus seven injected seams record+replay — time, RNG,
  UserDefaults, `URLSession` (via `URLProtocol`, no swizzle), locale/tz, keychain, file reads. See
  [`SEAMS.md`](SEAMS.md#implemented--the-oracleseams-target). Now **wired to the diff engine end-to-end**:
  a replayed seam run whose readings flow into behavior diffs `EQUIVALENT` vs. its golden and `DIVERGED`
  (localized) for a code change. **Un-injected reach started:** the `@Seamed` macro rewrites bare
  `Date()`/`Date.now`/`UUID()` (DEBUG-only) to the ambient `HaruspecSeam` cassette, so pure-Swift legacy
  code with no DI is reachable (`UninjectedReachTests`). **Singletons & ObjC** are handled at runtime
  (dispatch decides the tool): `SeamSwizzle` (`method_exchangeImplementations`) for `@objc dynamic`/ObjC
  methods — replaces the impl once, catching all callers — and a `.shared`-swap recording decorator for
  settable pure-Swift singletons (`SingletonSeamTests`). *Next:* extend the macro to `Int.random`/
  `arc4random`, and drive breadth with property-based generation at the seam.
- 📋 **Seam codegen — generate the plumbing, *declare* the boundary.** Hand-writing a paired
  `seam_*` method + swizzle install per singleton method is pure boilerplate the user shouldn't own.
  Split the work by dispatch, and — critically — split the **HOW** from the **WHAT**:
  - **HOW (100% generatable):** *Swift owned* → a `@SeamedSingleton` macro emits the recording
    decorator + `.shared`-swap install (distinct from `@Seamed`, which rewrites a method's *internals*;
    this wraps the method *boundary*). *ObjC* → a **runtime generic swizzler**
    (`class_copyMethodList` + `method_getTypeEncoding` + `imp_implementationWithBlock`) — no *static*
    gen needed because the runtime already has the metadata static gen would parse from headers. Start
    with nullary object/scalar getters (the common singleton seam); arg-bearing / variadic-arity
    methods need per-signature handling.
  - **WHAT (must stay declared, never assumed):** *which* methods are boundary seams is judgment. A
    thin **seam manifest** (or per-method marker) declares it; codegen does everything downstream.
    **Do not auto-seam every method** — replaying a non-boundary (pure or internally-mutating) method
    manufactures or hides divergences: a fast, confident, *wrong* verdict, the one outcome to avoid.
    Heuristics (methods touching known seam types) or agentic suggestion can *propose* the WHAT, but it
    stays a declaration.
  - The declared seam registry **doubles as the coverage map**: a change crossing a boundary not in the
    registry is exactly what downgrades the verdict — so this is a prerequisite for `CANNOT-VERIFY`
    below, not a detour.
- ⏳ **Tiered isolation** — the tool picks the cheapest faithful rung and is honest about it:
  **logic slice** (pure-Swift unit, seams replayed, *no simulator*, seconds) → **module cut** (changed
  file in its real module, downstream modules replayed) → **sim fallback** (UI-coupled code runs the
  real target on the simulator — a legitimate faithful tier, not a failure). Same diff engine at every
  rung.
- 🔬 **Seam-interception catalog** — the load-bearing (but non-blocking) research track that determines
  how much legacy code reaches the no-sim tier. Tracked in [`SEAMS.md`](SEAMS.md); each seam graduated
  to record+replay shrinks the `CANNOT-VERIFY` bucket.
- ⏳ **Three input sources, one harness** — **recorded** cassettes (fidelity), **property-based**
  generation at the seam (breadth — upgrades "equivalent on one path" toward "over a surface"), and
  **agentic interrogation** (aim). Coverage of the exercised surface is reported with every verdict.

## Distribution & rails

- ⏳ **MCP tool wrapper** — expose capture + diff as tools other agents (Claude Code, Cursor) can call:
  "verify behavioral parity of this change."

## Applications (callers of the engine)

- ⏳ **Swift 6 strict-concurrency migration ratchet** — one application among several: flip a module,
  triage diagnostics, propose Sendable/actor changes, verify with TSan-under-load + behavioral-diff, lock
  the ratchet, next module. Implement as a plugin/config over the engine — no Swift-6 logic in the core.
- 📋 **General parity-preserving refactors** — "refactor freely; the trace is the contract."
- 📋 **Perf-budget refactoring** — signpost + MetricKit before/after gates (launch, hang, memory).
- 📋 **Crash / hang reproduction** — ingest `xcresult` / MetricKit → symbolicate → restore sim state →
  replay → bisect to a repro.
- 📋 **UI configuration-sweep** — accessibility-tree + snapshot diffing across Dynamic Type, dark mode,
  RTL, locale, iPad multitasking.

## Open research (the hard core; budget for it)

- 🔬 **Trace canonicalization at scale** — clock jitter, address nondeterminism, dispatch ordering,
  concurrent partial-order traces. v0 handles the deterministic single-thread case.
- 🔬 **Replay determinism** — input seeding, sim-state restore, network stubbing so replays compare.
- 🔬 **Tolerance model depth** — richer declared deltas beyond exact/volatile/timing/unordered.
- 🔬 **Legacy reach** — ObjC dynamism (KVO/notifications/runtime) capture fidelity vs. pure Swift, and
  the record/replay fidelity of every I/O and nondeterminism seam. Cataloged and prioritized in
  [`SEAMS.md`](SEAMS.md) — this is what governs how much code reaches the no-simulator tier.

## Compose, don't rebuild (the "don't build this" list)

- Do not rebuild build/run/simctl plumbing — compose with XcodeBuildMCP (this is the engine behind the
  sim-fallback tier; the harness orchestrates it, it doesn't reimplement it).
- Do not build "Cursor for iOS" / a chat-in-IDE assistant.
- Build the hard part: the oracles themselves.
