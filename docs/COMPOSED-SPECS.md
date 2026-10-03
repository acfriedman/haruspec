# Composed specs: integration diffing

A briefing on extending Haruspec from one class at a time to clusters of collaborating classes. It
records the idea, its value proposition, a design sketch, and the hard parts.

**Status: proposal. Nothing here is built.** Determinism under concurrency leans on the injected
scheduling seams (`@Haruspec(schedules:)`, `WorkBacklog`), which are in flight on the
`injected-thread-seams` branch and not yet on `main`.

---

## The gap

A spec today drives one subject and replaces every collaborator boundary with a recording double.
Spec A checks A with B doubled; spec B checks B alone. Several kinds of bug pass both:

- **Correlated state.** A double's returns are generated seam values, each independent of the last.
  Real B answers from accumulated state: `available()` drops after `reserve()`. A port of A that
  depends on, or breaks under, that correlation is indistinguishable from the original
  (see [`LIMITATIONS.md`](LIMITATIONS.md): "records calls, not accumulated collaborator state").
- **Usage B's spec never sampled.** Spec B explores orderings of B's own ops under a budget. The
  sequence A actually sends may never come up, so a B port that breaks only on it passes.
- **Callbacks and concurrency across the boundary.** Completion delivery, reentrant calls back into
  A, B answering on another queue after A became an actor. A double stands in for all of it.
- **Diverging readings of one contract.** Each side's diff passes, yet the old pair worked and the
  new pair does not.

## The idea: move the cut line

A spec is a subject plus a **cut line**: the set of boundaries where real code stops and doubles
begin. An integration spec is the same spec with the cut line moved outward. That is a change of
resolution policy, not a new engine, and three properties of the codebase make it cheap:

- **One label per boundary.** `@Haruspec` emits a forwarder (`Traced<P>`, wraps a real conformer)
  and a double (`Double<P>`) under the same trace label. The A→B edge reads identically in a trace
  whether B is real or doubled, so unit and integration traces stay comparable.
- **One decision point.** `SeamContext.resolve(_:)` (`Sources/Spec/SystemResolution.swift`) is where
  a derived system decides what fills each collaborator parameter. Composition adds one rule: for
  this boundary, the real implementation wrapped in its forwarder.
- **Provenance already does the right thing.** A doubled collaborator's files are absent from a
  plan's dependency set (`PlanProvenance.swift`). With B live, its files join the set, so a PR that
  touches only B replays the composed spec.

A hand-wired version should already be expressible through `.system { … }` with a `Traced<P>`
around a real collaborator. It is untested.

## Value proposition

### Why integration tests are usually bad value

Teams under-invest in integration tests for three reasons. Each maps to something Haruspec already
removes:

| Usual cost | Why it hurts | What removes it |
| --- | --- | --- |
| Writing expected results | Hard to know for a multi-component flow, and they go stale | The baseline composition *is* the expected result |
| Flakiness | Queues, timers and async callbacks make runs disagree, so red stops being trusted | Held work drains in one order on virtual time (`WorkBacklog`) |
| Thin coverage | A hand-written test covers the paths someone thought of | Op orderings × seam domains (later, schedules) are explored and shrunk |

The other options each leave a gap. Unit tests with mocks encode assumptions about collaborators,
which are exactly what integration bugs violate. Contract tests (Pact-style) check the *shape* of
interactions, not what the combined system does. UI/E2E tests reach far but are slow, flaky, shallow
on state combinations, and cannot say where a failure came from.

### Bugs it catches that nothing cheap does

1. **Pair migrations.** `Cart` and `Inventory` are ported in the same sprint. Each unit spec is
   green, because doubles return independent values. The Swift `Inventory` now applies `reserve()`
   asynchronously on its queue, so `Cart`'s follow-up `available()` read is stale. Only the pair
   shows it.
2. **Delivery contracts across a boundary.** In a queue→actor port, B starts delivering its
   completion off main, and A assumed main. A's unit spec drives a double, so it never sees the move.
3. **Ordering assumptions.** B's port posts its notification before updating its state, and A's
   observer reads that state. Each side's own trace looks fine; the pair reads the wrong value.

### It permits refactors that cross class boundaries

This may matter more than the bugs. A unit spec makes its boundary a contract, so it **freezes** the
boundary. Take a behavior-preserving refactor across classes: move a method from A to B, extract a
class, merge two, collapse a chatty protocol into one call. A's spec diverges with a missing call and
B's with new behavior: two reds for no observable change. A composed spec gates on the cluster's
outer boundary, treats interior edges as advisory, reads green, and still reports which interior
edges moved.

Unit-level diffing verifies *ports*. Composition also verifies *restructuring*, which is most of what
a large migration is, and the work people are most afraid to do without a net.

### Smaller benefits

- **Localization.** Running {A_old, A_new} × {B_old, B_new} says whether a divergence is A's, B's,
  or neither alone: an *interaction* bug. Most integration failures start with a day of "whose bug is
  this?"
- **Low marginal cost.** With both units stamped and specified, a composed spec is mostly wiring: it
  reuses their ops, seam domains, tolerances and intent.
- **Runs only when needed.** In the continuous shape it replays only when A's or B's files change.
- **Honest scope.** If B reaches a queue, clock or framework nobody controls, the verdict is
  `CANNOT-VERIFY`, not a pass.

## Design sketch

1. **Declarative wiring.** Something like
   `.wire(Chime.self, baseline: BellChime.self, candidate: SwiftBellChime.self)`, implemented as a
   rule in `resolve` ahead of doubles. The wired collaborator is itself built through derived
   construction, so *its* collaborators (queues included) still resolve to doubles from the same
   context. Driving B only through A's op catalog keeps the ordering space small and realistic.
2. **Interior edges are advisory by default.** Gate on A's outer boundary and on B's own outbound
   edges; report A→B differences as localization hints. The semantic/structural split
   (`Tolerance.structuralComparison`) is the natural home.
3. **Pairwise attribution.** The 4× matrix above, opt-in because it multiplies cost.
4. **Shared collaborators.** When A and C both use B, interleave both subjects' ops against one live
   B. Shared-state bugs live here.
5. **Merged declarations.** Intent and tolerances from both specs, scoped so B's intent only excuses
   divergences that originate in B.

**A cheaper complement, contract stitching.** Without running the pair together: the calls A makes
into `Double<B>` during A's spec are an op script for B, so feed them to B's spec as an extra
ordering source (covers "usage B never sampled"). And draw A's double returns from values real B
recorded, which makes A's inputs realistic, though it does not restore correlation.

## Determinism

The rule for a composed spec: **control whatever is not a function of the spec's inputs; keep the
logic live.**

### Values: UUIDs, clocks, randomness

`SeamClock` and `SeamRNG` already exist. UUIDs are only redacted today (`volatileFields`). Two ways
to control them:

- **Inject a deterministic sequence** (a `SeamUUID`, like `SeamRNG`). Identical IDs on both sides,
  but fragile across ports: one extra UUID drawn by the candidate shifts every later ID into a
  cascade of value mismatches.
- **Canonicalize symbolically** by first appearance (`uuid#1`, `uuid#2`), as object identity
  already is. No production change, and robust to an extra draw.

Canonicalization should be the default, with injection where the value itself matters (sorting by
ID, hashing, persistence). Redaction is the worst choice here: IDs are what cross boundaries, and
redacting them hides "A passed B the wrong order ID." Aliasing keeps which ID went where.

### Schedules

On `injected-thread-seams`, a subject takes its queues as stamped scheduling protocols, and the
doubles hold every enqueue in the capture's `WorkBacklog`. The backlog lives on the `SeamContext`, so
every scheduling double resolved from one context feeds one backlog. In a composed spec, A's and B's
handed-off work merge into a single deterministic order, which is what makes the pair stable. A wired
B that builds its own `DispatchQueue` escapes that order; once B's sources join the subject's audit
denominator, the `dispatch` channel flags it.

Stable is not explored. One pinned schedule makes runs repeatable but narrow, and a race visible only
under another schedule passes silently, which breaks the "never a false `EQUIVALENT`" rule. The
backlog currently runs one fixed order, with three gaps, each with a natural hook:

1. **Held work runs after the last op** (except under a `sync` or an op awaiting a completion). "Op
   1's work lands before op 2 starts" never happens, nor any race where an op reads state without
   `sync`. The cheapest first sweep dimension is *where drains happen*: none, after every op, or at
   seeded points.
2. **`.concurrent` changes the domain label, not the order.** The next item is always the oldest
   ready one. The choice belongs there: the legal set is the oldest ready item per serial queue plus
   any ready item on a concurrent queue, and `Item` already carries `queue` and `discipline`.
   Recording choices in the cassette lets plans replay them and shrink a "failing schedule."
3. **A spawned task runs to completion in one step**, so two tasks never interleave at their
   `await`s. That is where actor reentrancy bugs live, the classic new bug of a queue→actor port.
   Closing it likely needs an executor that yields to the backlog at each suspension point.

**Schedules do not port across implementations.** In the continuous shape (same code, two builds),
replaying the same choice sequence mostly works, and a structural change shows up as a replay
mismatch. In the campaign shape, the candidate's queue items do not line up one-to-one with the
baseline's, so the comparison becomes outcome sets: every behavior the candidate shows under explored
schedules must be one the baseline can show. This is the partial-order item in
[`ROADMAP.md`](ROADMAP.md) made concrete.

A controlled scheduler finds logical interleaving bugs: ordering, atomicity split across blocks,
deadlocks (detectable when every held item waits). It does not find memory-level races inside a
block, because each block runs whole. That stays TSan's job, in a separate live run.

### What stays live

- **In-process collaborators:** live. That is the point.
- **Out-of-process state** (network, keychain): still recorded. Live, it brings back
  nondeterminism and environment dependence.
- **Files and databases:** live but isolated, a fresh scratch directory or in-memory store per
  capture through `.provides`.

## Hard parts and limits

- **Concurrency.** Real collaborators add genuine parallelism; the partial-order problem bites
  harder.
- **The audit grows.** B's sources join the completeness denominator, so `CANNOT-VERIFY` is likelier
  until B's own seams are covered.
- **Nondeterminism.** Live B may read clocks, defaults or I/O its doubled form never touched. Those
  need seams, or the verdict is `UNSTABLE`: honest, but friction.
- **Cost.** A composed spec is slower than its unit specs, and attribution multiplies that. Opt-in,
  not default.
- **A regression oracle, not a correctness oracle.** A baseline bug is preserved.
- **Not a replacement for E2E** on view wiring or real framework behavior.
- **Both sides must be injectable**, queues included.

## Where it pays off

- Tightly coupled clusters in an Objective-C→Swift campaign, where ports land in pairs anyway.
- Swift 6 concurrency migrations: work moving between domains across a boundary is an integration
  bug by definition.
- Any refactor that moves responsibility between classes.

## Suggested order

1. Symbolic UUID canonicalization. Small, no production change, pays off for unit specs too.
2. `.wire` through `resolve`, with interior edges advisory by default.
3. Drain-point sweep on the backlog (gap 1 above): the smallest step from stable to explored.
4. Contract stitching.
5. Ready-set schedule choice with outcome-set comparison and schedule coverage in the qualification
   block. Ship steps 2–3 without it only with the qualification saying one schedule was explored.
