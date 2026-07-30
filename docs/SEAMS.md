# Interceptable Seams — catalog & research roadmap

The **reach** of the oracle — how much real legacy code it can isolate and replay *headlessly*,
without a simulator round-trip — is proportional to how many nondeterminism/I/O **seams** it can
**record** and **replay**. This doc is the source of truth for that reach.

A *seam* (Feathers) is a place where behavior crosses the boundary of the unit under test: a clock,
a network call, a notification, a singleton, a disk write. The seam-harness strategy is:

> **Record the seam once from the golden branch; replay the *same* transcript into both branches;
> diff the outputs.** The stub is a recorded transcript of the real dependency, not a synthesized
> guess — so fidelity survives and the diff is attributable to the changed code by construction.

Status: ✅ record+replay both work · 🔨 in progress · ⏳ next · 📋 backlog · 🔬 open research

---

## Why this is load-bearing (but not a blocker)

More intercepted seams → more code the oracle can run at the fast, no-simulator tier, and a smaller
"cannot verify" bucket. But an *un*intercepted seam is never a blocker for the whole idea — it just
forces the change into a higher (slower, more faithful) isolation tier, or an honest abstain:

| Tier | What runs | Requires |
|------|-----------|----------|
| **Logic slice** | changed unit extracted + seams replayed from transcripts | pure-Swift unit; every crossed seam is record+replay-able |
| **Module cut** | changed file in its real module; *downstream* modules replayed | module compiles headless; downstream seams replay-able |
| **Sim fallback** | the real target on the simulator | UI-coupled code, or a seam we can't yet intercept faithfully |

The rule is **never silently mock an uncaptured seam.** If a change crosses a seam we can't record,
the verdict escalates the tier or returns `CANNOT-VERIFY` — a false `EQUIVALENT` is the one
catastrophic outcome and this ledger exists to prevent it. Every row moved toward ✅ shrinks the
abstain bucket and grows the headless surface; honest gaps are the cost of soundness, not a failure.

---

## The seam ledger

Prioritized by **frequency in real legacy code × determinism impact × interception cost.** Time,
randomness, network, and persistence sit at the top of the funnel — they show up everywhere, wreck
determinism, and have clean interception points.

### Time & ordering
| Seam | Mechanism | Record | Replay | Notes |
|------|-----------|:------:|:------:|-------|
| Injectable logical clock | ctor/ambient injection | ✅ | ✅ | Engine's canonical clock; **`SeamClock` adds cassette record/replay of wall-clock reads**. |
| `Date()` / `Date.now` (bare call) | source shim (`@Seamed`) | ✅ | ✅ | `@Seamed` rewrites bare `Date()`/`Date.now` → ambient `HaruspecSeam` cassette, **DEBUG-only** (release keeps the bare call). No DI needed. |
| `CACurrentMediaTime`, `mach_absolute_time`, `DispatchTime.now` | interpose | 📋 | 📋 | Timing-budget captures depend on this. |
| `Timer` / `RunLoop` scheduling | swizzle / virtualized clock | 🔬 | 🔬 | Needs a virtual scheduler to replay deterministically. |

### Randomness & identity
| Seam | Mechanism | Record | Replay | Notes |
|------|-----------|:------:|:------:|-------|
| `UUID()` (bare call) | source shim (`@Seamed`) / redaction | ✅ | ✅ | `@Seamed` rewrites bare `UUID()` → ambient cassette (DEBUG-only, no DI); also redactable via the tolerance model. |
| `SystemRandomNumberGenerator`, `Int.random(using:)` | injectable RNG (`SeamRNG`) | ✅ | ✅ | `SeamRNG` records/replays the `next()` stream via `Cassette`; drop into any `random(in:using:)`. Bare `Int.random(in:)` (no `using:`) still needs a shim. |

### Network
| Seam | Mechanism | Record | Replay | Notes |
|------|-----------|:------:|:------:|-------|
| `URLSession` (shared + delegate) | `URLProtocol` (`CassetteURLProtocol`) | ✅ | ✅ | Record status+body from live, replay **offline through a real `URLSession` — no code change, no swizzling**. v0 keys by method+URL; headers/request-body/streaming next. |
| WebSocket / streaming | `URLProtocol` / proxy | 🔬 | 🔬 | Ordered, timed frames — partial-order replay. |
| Third-party HTTP (Alamofire, etc.) | ride the `URLProtocol` seam | 📋 | 📋 | Most route through `URLSession` underneath. |

### Persistence & storage
| Seam | Mechanism | Record | Replay | Notes |
|------|-----------|:------:|:------:|-------|
| `UserDefaults` | injected `SeamDefaults` / shim | ✅ | ✅ | `SeamDefaults`: reads recorded/replayed per key, writes kept in-memory. Injected boundary today; swizzling `UserDefaults.standard` is the un-injected path. |
| `FileManager` / file I/O | injected `SeamFileSystem` / shim | ✅ | ✅ | `SeamFileSystem`: reads recorded/replayed by path, writes in-memory with read-your-writes. Injected boundary today. |
| Keychain | injected `SeamKeychain` / shim | ✅ | ✅ | `SeamKeychain`: record the token once, replay it so an auth gate never blocks a headless run. |
| CoreData / SwiftData | in-memory store | 🔬 | 🔬 | In-memory store type helps; relationship/fetch ordering is the hard part. |
| SQLite / GRDB | in-memory db | 🔬 | 🔬 | Determinism of query ordering. |

### Concurrency & dispatch
| Seam | Mechanism | Record | Replay | Notes |
|------|-----------|:------:|:------:|-------|
| `DispatchQueue` / `OperationQueue` | virtualized executor | 🔬 | 🔬 | Ordering across hops — ties to partial-order canonicalization. |
| `Task` / actor suspension points | custom executor | 🔬 | 🔬 | Async capture end-to-end is already open in ROADMAP. |

### System & app services
| Seam | Mechanism | Record | Replay | Notes |
|------|-----------|:------:|:------:|-------|
| `NotificationCenter` posts | `NotificationInterceptor` | ✅ | ⏳ | Record shipped; replay (re-post recorded notifications) is next. |
| KVO observed changes | `KVOInterceptor` | ✅ | ⏳ | Same — record shipped, replay next. |
| Combine publishers | operator tap | 📋 | 📋 | Record emitted values + completion, replay as a fixture publisher. |
| Locale / TimeZone / Calendar | injected `SeamEnvironment` | ✅ | ✅ | `SeamEnvironment`: locale/timezone/calendar reads recorded/replayed. Cheap and high-value for the UI configuration-sweep application. |
| Feature flags / remote config | protocol injection | 📋 | 📋 | Usually already behind a protocol — an easy seam. |
| `CLLocationManager`, `AVFoundation`, sensors | protocol wrapper / swizzle | 🔬 | 🔬 | Device services; record a session, replay the sequence. |
| `UIApplication` / app-lifecycle state | shim | 📋 | 📋 | Background/foreground transitions as recorded events. |

### ObjC dynamism & DI seams

**The canonical path here is the injectability precondition:**
ask for the *smallest behavior-preserving refactor* that makes the boundary injectable — a settable
`.shared` behind an extracted protocol (**one file: the singleton itself**; all N call sites untouched) —
then observe it through clean DI with **no runtime interception**. Runtime swizzling is no longer a
standing mechanism in this column; it survives only as the *one-shot bootstrap* that certifies the
injectability refactor is EQUIVALENT (then is retired), and as the irreducible no-source-binary residue.

| Seam | Mechanism | Record | Replay | Notes |
|------|-----------|:------:|:------:|-------|
| Protocol boundaries | direct injection | ✅ | ✅ | The *easy* case — clean DI needs no interception. |
| Singletons / `.shared` | settable-`.shared`-behind-protocol → inject recording double | ✅ | ✅ | The one-file injectability refactor: extract a protocol, keep `+sharedInstance` as callers use it, make the backing store settable. The DEBUG/harness path sets a recording double (a generated `@TracedForwarder` seam); production ships the real one. Certified once by a swizzle bootstrap, then pure DI. |
| Global mutable state | source shim / interpose | 🔬 | 🔬 | Snapshot + restore around the replay. |
| Swizzle bootstrap / no-source binary | `SeamSwizzle` (`method_exchangeImplementations`) | ✅ | ✅ | **Not a standing mechanism.** One-shot: swizzle the pre-refactor `@objc dynamic`/ObjC singleton to capture a golden, apply the injectability refactor, diff → EQUIVALENT certifies the seam; then drop the swizzle. Also the last reach for a third-party *binary* framework with no source to make injectable. Bootstrap proven on a real `.m`/`.h` singleton (`LegacyObjC`). |

### Third-party SDKs
| Seam | Mechanism | Record | Replay | Notes |
|------|-----------|:------:|:------:|-------|
| Analytics / logging / silent singletons | injected recording seam (`@TracedForwarder`) | ✅ | n/a | *Observed*, not stubbed: make the collaborator injectable (settable-`.shared`-behind-protocol), inject a generated `@TracedForwarder` that records each outbound call as a semantic `effect` event before forwarding, so a dropped/altered call diverges. A *capture* channel (watch the boundary), not a value-replay seam — nothing to replay. Clean DI, no runtime interception. |
| Crash reporters | no-op in DEBUG harness | 📋 | 📋 | Suppress side effects during replay. |

---

## Implemented — the `HaruspecSeams` target

The **`Cassette`** primitive is built: record-once, replay-into-both, JSON-serializable (same bundle
discipline as a trace), and it surfaces unrecorded interactions as `SeamMiss`es rather than fabricating
a response. Proven by `SeamReplayTests` — record a golden run, replay reproduces it exactly, two
replays agree, and a logic change under the *same* cassette still diverges (attributable to the code).

It's also **wired to the behavioral-diff engine end-to-end** (`SeamHarnessEndToEndTests`): production
logic reads seams (clock + RNG bucket + config) whose values *flow into observable behavior*
(notifications + markers) captured in a `TraceRecorder`. An un-replayed run diverges — tolerances can't
absorb values that flow into the output — while replaying the cassette makes the baseline reproduce its
golden trace `EQUIVALENT`, and the changed branch is `DIVERGED` and localized, through `BehavioralDiff`.
This is the seam harness's version of the engine's original validation gate.

Seven seams knocked off the ledger against it, all pure-Swift and no simulator:

- **`SeamClock`** (time) — cassette record/replay of wall-clock reads.
- **`SeamRNG`** (randomness) — a `RandomNumberGenerator` whose `next()` stream is recorded/replayed.
- **`SeamDefaults`** (persistence) — `UserDefaults`-style reads recorded/replayed per key; writes in-memory.
- **`CassetteURLProtocol`** (network) — records status+body from live, replays offline through a real
  `URLSession`, no code change and no swizzling.
- **`SeamEnvironment`** (locale / timezone / calendar) — reads recorded/replayed.
- **`SeamKeychain`** (auth-gate token) — record the token, replay it headlessly.
- **`SeamFileSystem`** (file I/O) — reads recorded/replayed by path; writes in-memory (read-your-writes).

Most do the clean **injected** boundary. The **un-injected** reach has started too: `HaruspecSeam` (an
ambient, task-local cassette) plus the **`@Seamed`** macro, which rewrites bare `Date()` / `Date.now` /
`UUID()` call-sites in a type's methods to route through it — **only under `#if DEBUG`**, so release
builds keep the original calls and production is untouched. `UninjectedReachTests` proves it on a
`LegacySession` that has no injected seam at all (a fresh `LegacySession()` calling bare `Date()`/`UUID()`
replays identically under a cassette, and passes straight through when none is bound). That's the
mechanism for reaching real legacy code, which never has clean DI; `Int.random`/`arc4random` are the
next macro extensions.

**Singletons & ObjC — make the boundary injectable, don't intercept it.** A shared singleton called
from everywhere used to force *runtime* interception (there's no injection point). The
injectability precondition removes that forcing
function: ask for the one-file, behavior-preserving refactor that gives the boundary an injection point,
then observe through clean DI.

- **ObjC / `@objc dynamic` singleton with source** (Foundation-style, most legacy `NSObject` singletons)
  → extract a protocol, keep `+sharedInstance` exactly as callers use it, make the backing store settable
  (`+setSharedInstance:`). One file changes; all call sites are untouched. The harness sets a recording
  double (a generated `@TracedForwarder`); production ships the real one.
- **pure-Swift singleton with a settable `.shared`** → the same shape natively: swap in a recording
  subclass decorator. The call-site is untouched; only the global is redirected (`SingletonSeamTests`).
- **pure-Swift `final` + `let shared` + non-`@objc`** → the genuine hold-out: `@Seamed` if you own the
  source, or make it settable, else `CANNOT-VERIFY`.

The **chicken-and-egg** — "making it injectable is itself an unverified refactor" — resolves cleanly:
swizzle the pre-refactor singleton **once** to capture a golden, apply the refactor, diff → EQUIVALENT
certifies the seam is behavior-preserving; then the swizzle is dropped and every downstream verification
rides clean DI. This bootstrap is proven end-to-end on a **genuine ObjC `dispatch_once` singleton**
(`LegacyObjC/LegacyObjCManager.m`, a real `.m`/`.h` target) whose `deviceToken` carries *no annotation at
all* (`ObjCSeamTests`). Swizzling as a one-shot certifier, never as a standing runtime mechanism — so the
whole `_objc_msgForward` / `_stret` / struct-arg edge list simply doesn't exist on the canonical path.

---

## Interception mechanisms (fidelity vs. intrusiveness)

Layered, cheapest-and-most-faithful first:

1. **Protocol injection** — the code already takes a protocol; hand it a replay double. Zero
   intrusiveness, perfect fidelity. Free where the code is clean.
2. **Injectability precondition (settable-`.shared` behind a protocol)** — the one-file,
   behavior-preserving refactor that turns an un-injectable singleton *into* case 1: extract a protocol,
   make the backing store settable, leave all call sites untouched. Certified once by a swizzle bootstrap
   (case 6), then perfect-fidelity DI forever. The canonical tool for legacy singletons with source.
3. **Environment / suite override** — `UserDefaults` suites, `TimeZone`/`Locale` overrides,
   in-memory stores. Cheap, no swizzling.
4. **`URLProtocol` registration** — Apple's sanctioned network seam. High value, no swizzling.
5. **Source shim (macro)** — rewrite `Date()` / RNG call-sites through an ambient provider, confined
   to the DEBUG/opt-in path like `@Traced`. Faithful, opt-in. **Implemented for `Date()`/`Date.now`/
   `UUID()`:** `@Seamed` (on a type) rewrites those bare calls to the ambient `HaruspecSeam` cassette,
   emitted only under `#if DEBUG` so release builds are byte-for-byte untouched. This is how the harness
   reaches legacy code with no DI. Manual value-level syntax walk (the prebuilt SwiftSyntax can't link a
   `SyntaxRewriter` subclass). `Int.random`/`arc4random` rewriting is the next extension.
6. **Swizzle bootstrap (`SeamSwizzle`)** — `method_exchangeImplementations` on an `@objc dynamic`/ObjC
   method, used **once** to certify that "make this singleton injectable" is EQUIVALENT, then retired
   (case 2). Also the last reach for a third-party *binary* framework with no source to refactor. Not a
   standing runtime mechanism. DEBUG-only install.
7. **DYLD interposing / `lldb` Python** — the last resort for system symbols we cannot annotate or make
   injectable. Highest reach, highest cost.

The rule was *"production code is never modified."* It is now the **injectability precondition**: trade a
*tiny, self-verifying* refactor (one file — a settable `.shared` behind a protocol) for the elimination of
the entire runtime-interception column. Every mechanism still lives in the external harness behind
`DEBUG` / opt-in; the one admitted production touch is a bounded, behavior-preserving seam whose safety is
*certified* by the swizzle bootstrap before anything downstream relies on it.

---

## The record/replay contract

- **Cassette** — an ordered, keyed transcript of boundary interactions captured during the golden run
  (same JSON-bundle discipline as trace capture).
- **Matching** — a replayed call finds its recorded response by *seam id + canonicalized args + call
  ordinal*, reusing `HaruspecCore` canonicalization so volatile fields don't defeat the match.
- **Unrecorded interaction** — replay hits a call with no matching entry. This is **both** a
  behavioral-change signal (the change altered the boundary) **and** a coverage event. Policy:
  **surface it, never fabricate a response.** *Now wired to the verdict:* `Cassette.coverage(declaring:)`
  turns each `SeamMiss` into an `.unrecorded` coverage gap, and `VerificationResult` downgrades an
  otherwise-`EQUIVALENT` diff to **`CANNOT-VERIFY`** — the miss means replay fell back to a live read, so
  the environment wasn't held identical and an equivalent can't be trusted. The declared seam registry is
  the coverage map (defaulting to the golden's recorded seams); coverage — exercised / declared — is
  reported with every verdict.
- **Attribution** — record on the golden branch, replay the same cassette into *both* branches. The
  golden is self-consistent by construction; any divergence is attributable to the candidate's code.
- **Determinism** — replay must be order-stable; concurrent seams need the partial-order
  canonicalization tracked in ROADMAP's open-research section before they leave 🔬.

---

## How the harness gets its inputs

One replay harness, three complementary input sources — recorded gives fidelity, generated gives
breadth, agentic gives aim:

- **Recorded** cassettes — the real inputs the system actually saw (fidelity; proves equivalence on
  the observed path).
- **Property-based / fuzz** generation at the seam — inputs the recording never hit (breadth; this is
  what upgrades "equivalent on one path" toward "equivalent over a surface"). Reuses the seeded-RNG
  seam above.
- **Agentic interrogation** — targeted probing of branches the diff or the coverage map flags as thin.

Coverage — the fraction of the change's behavioral surface actually exercised — is reported alongside
every verdict, because `EQUIVALENT` over 20% of the surface is nearly worthless and `EQUIVALENT` over
95% is the product.

---

*Living document. Rows graduate ✅ as record **and** replay land; ROADMAP.md links here from
"Isolation & headless replay" and "Open research → Legacy reach."*
