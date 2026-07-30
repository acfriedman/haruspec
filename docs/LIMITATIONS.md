# Known limitations

Constraints of *shipped* code — deliberate trade-offs and sharp edges worth revisiting, distinct from
the forward feature work in [`ROADMAP.md`](ROADMAP.md) (future capability) and the seam fidelity ledger
in [`SEAMS.md`](SEAMS.md) (legacy reach). A limitation here is something that works today but could be
enhanced; when one is closed, delete it (or move it to the roadmap if it grows into a feature).

Each entry: **what breaks / is missed**, **why it's this way**, and a note on **how to revisit**.

---

## Structural value capture (`RuntimeValue.canonical`)

`Sources/HaruspecTrace/RuntimeValue.swift` turns a type-erased runtime `Any` into a diffable
`CanonicalValue`. Order: bridged JSON scalars/collections → `Encodable` → **structural reflection**
(Obj-C property list, then Swift `Mirror`) → `String(describing:)`. The reflection fallback deletes the
old "must be `Encodable`" tax (no hand-written `Codable` mirror DTO needed), but has edges:

- **KVC can raise an uncatchable Obj-C exception.** The Obj-C branch reads each declared property via
  `value(forKey:)`. A property that isn't KVC-compliant (unusual C-struct/union types, a getter that
  throws) raises an `NSException` Swift cannot `try/catch`, which would crash the capture rather than
  degrade. Fine for ordinary `@property`-declared objects (the migration `Receipt` case); a hazard for
  arbitrary `NSObject` subclasses. *Revisit:* guard the read via a small Obj-C `@try/@catch` shim (or a
  KVC-compliance pre-check) and fall through to string on failure.

- **Swift `NSObject` subclasses expose only their `@objc` surface.** `structural` tries the Obj-C
  property list first and returns if it finds anything, so a Swift `NSObject` subclass with a mix of
  `@objc` and plain stored properties captures only the `@objc` ones — the non-`@objc` Swift stored
  properties are silently dropped (they're invisible to `class_copyPropertyList`, and `Mirror` is never
  consulted once the Obj-C branch succeeds). *Revisit:* union the two sources for `.class` values rather
  than short-circuiting.

- **All declared Obj-C `@property`s are captured, including computed/derived ones.** The property-list
  walk doesn't distinguish stored from readonly-computed, so derived or volatile values (a formatted
  `description`-like field, a cached timestamp) land in the payload and can add diff noise. *Revisit:*
  allow declared redaction of property names, or skip readonly computed properties by attribute.

- **Depth cap of 8; deeper graphs truncate to a string.** `maxDepth = 8` bounds pathological object
  graphs. A legitimately deeper struct/object tree gets `String(describing:)` at the leaf, which is
  opaque and un-diffable. *Revisit:* raise the cap, or make it configurable, once we have a real case.

- **Reading every property can trigger side effects.** Both branches read *all* properties eagerly
  (KVC / `Mirror`), so lazy-initializing or side-effecting getters fire during capture. Usually benign;
  a concern for getters that mutate or perform I/O. *Revisit:* no clean fix without opt-out annotation.

- **Reference cycles are broken; sibling sharing is not de-duplicated.** A `visited` set
  (`Set<ObjectIdentifier>`) breaks reference cycles, but a shared object reached via two sibling paths is
  expanded twice — correct, but wasteful for large shared graphs. *Revisit:* only if payload size bites.

---

## Collaborator observation (injected recording seams)

A silent collaborator — a singleton the SUT calls for a side effect that emits no notification and fires
no KVO (reserve stock, enqueue analytics) — is observed by **injection**, not interception. The
injectability precondition (see [`SEAMS.md`](SEAMS.md)) asks for the one-file
refactor that makes the boundary injectable (settable-`.shared` behind a protocol), and the harness
injects a generated `@TracedForwarder` that records each outbound call as a semantic `effect` event before
forwarding. A dropped call surfaces as a `missingEvent`; an altered argument as a `valueMismatch`.

This **retired the runtime `forwardInvocation:` spy** (`CollaboratorSpy` / `HaruspecObjCShim`, removed), and
with it its whole edge-list — the entire column collapsed rather than being patched one caveat at a time:

- No **`_objc_msgForward` / `_stret`** hazard — there is no message-forwarding trampoline; a forwarder is
  an ordinary typed method that reads its arguments directly, so struct returns and struct arguments are
  captured by normal Swift, not degraded to a `"<encoding>"` marker or skipped.
- No **"ObjC-dispatched methods only"** limit — a forwarder wraps a *protocol*, so it works for pure-Swift
  `static`/`final` collaborators too, exactly the case swizzling couldn't reach.
- No **persistent `orcl_spy_*` alias** left on the class, and no runtime mutation to install/restore.

What carries over is a property of *capture semantics*, not of any mechanism:

- **Records calls, not accumulated collaborator state.** A real singleton's internal state accumulates
  across a scenario's many internal runs; the forwarder deliberately records the *call* (label + args),
  which stays deterministic. A test that needs to assert on accumulated state must read it directly.

The residue is the **no-source-binary holdout**: a third-party *binary* framework with no source can't be
made injectable, so a one-shot swizzle/interpose is the only reach there (see `SeamSwizzle`).
