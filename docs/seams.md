# Seams: what the oracle controls

Haruspec drives the baseline and the candidate with identical inputs and diffs what they did. A
difference means something only if both sides were handed the same world. This page covers how that
happens: what crosses the subject's boundary, how each crossing is controlled, and what Haruspec says
when one isn't.

A **seam** is a place where something from outside reaches the subject: a collaborator it calls, a
value it reads (the clock, a fresh identifier), a queue it hands work to. Haruspec controls the seams a
subject takes through its initializer. A seam it cannot control, it names: the verdict reads
`UNSTABLE`, the audit flags the channel, or the verdict abstains with `CANNOT-VERIFY`. It never stands
in a guess.

The five-minute video version of this page:

https://github.com/user-attachments/assets/272c05c2-c5f6-4e13-bf2c-840e225ffe43

## The boundary

Everything Haruspec compares crosses the subject's boundary, in one of two directions.

**Recorded:** calls into the subject (through the stamp's forwarder), calls out to its collaborators
(through their stamped doubles), notifications (through the capture's recording center), and the
observed properties the harness reads back.

**Supplied:** what the subject reads in. Operation arguments, a collaborator's answers, a clock
reading and a fresh identifier come from the spec's seams, recorded once from the baseline and replayed
into both sides. Work the subject hands off runs in one order the capture sets.

Anything that reaches the subject around the boundary (a singleton called from a method body, a bare
`Date()`, a direct `DispatchQueue.main.async`) is a seam nobody controls.

## Through the initializer

The precondition for all of it, the **injectability precondition**: the subject takes its seams through
its initializer. Its collaborators, the notification center it posts to, the queues it hands work to,
and the sources of any values it would otherwise make up. Paste that initializer into the stamped
protocol and construction derives: `.baselined(on: CartManager.self)` and `check(SwiftCart.self)` build
both sides through it. The dogfood cart's boundary protocol, abridged to its initializer:

```swift
@Haruspec
protocol Cart: AnyObject {
    init(
        inventory: InventoryReserving,
        analytics: AnalyticsTracking,
        notificationCenter: NotificationCenter,
        orderArchive: OrderArchiving,
        stateQueue: SerialQueueing,
        newOrderID: @escaping () -> UUID,
        clock: @escaping () -> Date
    )
}
```

Legacy code usually reaches these from inside method bodies (`[AnalyticsTracker shared]`,
`NotificationCenter.default`, `Date()`). The fix is small, behavior-preserving, and touches one file:
take each seam as an initializer parameter, defaulted to the real one, so production and every call
site build the class exactly as before.

```swift
final class ReceiptPrinter {
    private let newID: () -> UUID
    private let now: () -> Date

    init(newID: @escaping () -> UUID = { UUID() }, now: @escaping () -> Date = { Date() }) {
        self.newID = newID
        self.now = now
    }
}
```

A singleton is the same case: a parameter whose default is the shared instance
(`inventory: InventoryReserving = InventoryLedger.shared()`), with its protocol stamped so the capture
hands in a double. A singleton left in a method body is not on the audit's list: its calls run live on
both sides, unrecorded, and whatever it returns reaches the subject uncontrolled.

For what an initializer cannot reach (a binary framework with no source, or certifying the refactor
above against the code before it), `SeamSwizzle.exchange(_:_:with:)` swaps an `@objc dynamic` or
Objective-C method for a paired one that reads through `Seam.cassette`, and `Seam.bind(_:_:)` binds a
cassette around a closure. Both are for a harness you write yourself: a spec's capture does not bind
`Seam.cassette`. Swizzle once to record, make the refactor, compare, then delete the swizzle.

## Collaborators

Stamp the collaborator's protocol in the test target, refining the protocol the subject's initializer
names:

```swift
@Haruspec
protocol Inventory: InventoryReserving {
    func reserve(sku: String, quantity: Int)
    func stock(sku: String) -> Int
    func reset()
}
```

The stamp emits `DoubleInventory`, which serves both `Inventory` and `InventoryReserving`. A double has
nothing behind it: it records each call, and the call is what the diff compares. Where the subject reads
an answer (a return value, a property), the double reads it from the seam `"<label>.<member>"`:

- the type's zero by default (an empty collection, `nil` for an optional custom type);
- swept when the spec declares a domain: `.vary { Seam("Inventory.stock", .int(0 ... 12)) }`;
- keyed by the call's arguments, so a candidate asking `stock(sku: "MUG")` gets the answer the baseline
  got for that question, whatever order it asks in;
- for a required custom type, the factory the spec declares with `.generates` (see [specs.md](specs.md));
- for a completion block, delivered inside the call with generated arguments, each its own seam
  (`"Carrier.rate.completion.cents"`).

A network client is a collaborator like any other: stamp its protocol, and the double answers with
generated responses.

### How a check resolves initializer parameters

Every build a capture makes (a baseline bound by type or initializer, `check(SwiftCart.self)`,
`check(SwiftCatalogPrefetcher.init)`) resolves each initializer parameter in this order:

1. a resource the spec provides for that type (`.provides`);
2. for an optional parameter (an unannotated Objective-C initializer), whatever its wrapped type
   resolves to;
3. for `NotificationCenter`, the capture's recording center;
4. the one stamped double that serves that type;
5. a packaged default, such as the in-memory store `HaruspecCoreData` provides for
   `NSManagedObjectContext`.

If nothing serves a parameter, or two doubles do, the capture traps with a message naming the
declaration to write. A guessed collaborator would be a silent wiring change, so there is no fallback.
To wire a build by hand, construct doubles through the context, which registers them as injected:
`.baselined { context in LegacyQuoter(queue: context.double(DoubleQuoterQueue.self)) }`.

**Resources** are infrastructure the subject runs on rather than a boundary it calls: an in-memory
store, a scratch directory, a value source. Nothing is recorded at a resource; its state shows up
through the subject's own reads. The maker runs once per capture, so every probe gets a fresh instance,
and a resource can be provided by its initializer: `.provides(ImageLoader.init(queue:deliveryQueue:))`.

## Values

A value the subject reads from the world is a seam: the clock, a fresh identifier, random numbers, user
defaults, the keychain, a file, the locale. Take the source through the initializer, then provide it
from the spec, in one of two shapes.

**A fixed source.** Both sides draw the same values in the same order. The dogfood cart's spec provides
sequential identifiers (a fresh counter per capture, so each side starts at `…0001`) and one instant:

```swift
// A receipt's order ID and timestamp, held still per capture.
.provides((() -> UUID).self) { _ in Minted.identifiers() }
.provides((() -> Date).self) { _ in { Minted.instant } }
```

**A source read through the seams.** Read the value through the capture's context (`int`, `double`,
`bool` or `string(_:default:)`) and it is recorded from the baseline, replayed into the candidate, and
swept like any other input. The dogfood fulfillment spec's `StoreClock.now(_:)` parses
`context.string("Clock.now", default: instants[0])`, and the spec sweeps it over named instants
(cutoffs, a Saturday, two holidays):

```swift
.provides((() -> Date).self) { context in { StoreClock.now(context) } }
.vary {
    Seam("Clock.now", .oneOf(StoreClock.instants))
}
```

### Value seams for a harness you hold

`HaruspecSeams` also ships ready-made recorders for the common value seams. Each takes a `Cassette` in
its initializer and records under its own track:

| Seam | Type | What it records |
| --- | --- | --- |
| Clock | `SeamClock` | each `now()` reading, seconds since 1970 (`clock`) |
| Randomness | `SeamRNG` | each `next()`, as a `RandomNumberGenerator` for `random(in:using:)` (`rng`) |
| User defaults | `SeamDefaults` | `string`, `integer` and `bool` reads per key (`defaults.<key>`); writes stay in memory |
| Keychain | `SeamKeychain` | reads per key (`keychain.<key>`); writes stay in memory and read back |
| File system | `SeamFileSystem` | reads per path (`fs.read:<path>`); writes stay in memory and read back |
| Environment | `SeamEnvironment` | locale, time zone and calendar identifiers (`env.locale`, `env.timezone`, `env.calendar`) |
| Network | `CassetteURLProtocol` | status and body per method and URL, served offline through a real `URLSession`; no headers |

They are for a harness you write yourself. A spec's capture does not hand out its cassette, so inside a
spec, provide the source as above. In a harness, record with `Cassette()` and replay with
`Cassette(replaying:)`:

```swift
let recording = Cassette()
let golden = SeamClock(cassette: recording).now()

let replay = Cassette(replaying: recording.snapshot())
XCTAssertEqual(SeamClock(cassette: replay).now(), golden)

let session = URLSession(configuration: CassetteURLProtocol.install(cassette: replay))
```

## The cassette: record once, replay into both

Every seam read in a capture (an operation's argument, a double's answer, a value read through the
context) lands on the capture's cassette, one ordered track per seam key.

- The baseline runs first, recording. A seam with a declared domain records the domain's first
  interior value; any other records its default.
- Each probe replays a cassette into both sides: the baseline, then the candidate, answered as the
  baseline was, including the answers it bound to arguments.
- Probes vary the cassette (and the ordering), never the code: each declared domain is swept across
  them.
- A recorded plan stores every probe's cassette, so a replay on a branch is answered exactly as `main`
  was.

A replay that reads past the end of a track gets no invented value. The cassette falls back to the
live default and records a miss, and an otherwise-equivalent verdict reads `CANNOT-VERIFY` with
`⚠︎ unrecorded reach: <seam> (replay fell back to live)`. A domain declared for a key nothing read is
the same kind of gap: `declared domain matched nothing`.

## Threads as collaborators

A subject that hands work to another thread takes the queue, or a task spawner, in its initializer.
The app owns the protocol and conforms its production queue to it (a `DispatchQueue` extension, or a
small wrapper class). The test target stamps a protocol that refines it, with the discipline it honors:

```swift
@Haruspec(schedules: .serial)
protocol StateQueue: SerialQueueing {
    func async(_ work: @escaping () -> Void)   // held, run in order
    func sync(_ work: () -> Void)              // the queue's held work, then inline
}
```

A scheduling protocol's requirements take one of five shapes, read off the signature. The stamp
rejects anything else at compile time, as well as a `sync` on a `.main` protocol and a `sync` beside a
`spawn`.

| Requirement | Under test |
| --- | --- |
| `func async(_ work: @escaping () -> Void)` | held, run in enqueue order |
| `func after(_ delay: TimeInterval, _ work: @escaping () -> Void)` | held on virtual time; fires once nothing else is ready, recording a `timer` event |
| `func notify(_ group: DispatchGroup, _ work: @escaping () -> Void)` | held until the group empties |
| `func sync(_ work: () -> Void)` | the queue's ready held work, then the block, inline |
| `func spawn(_ operation: @escaping @Sendable () async -> Void)` | an unstructured task, held, then awaited whole |

The discipline names the domain the work records on: `.serial` is `queue(serial):<label>`,
`.concurrent` is `queue(concurrent):<label>`, and `.main` is `main`, with the work run on the main
thread. A port that changes discipline depends on a different protocol, and the diff sees a different
domain.

Under test, the double holds each piece of work in the capture's backlog. The capture runs held work
one item at a time, in enqueue order, after the operations (and at settle points, below): the same
order every run. Each item is attributed to the operation that enqueued it. A backlog that never
empties (a timer that re-arms itself) stops after 10,000 items and leaves the marker
`⟨haruspec: scheduled work still held at snapshot⟩`. Structured children of held work
(`withTaskGroup`, `async let`) inherit its domain and finish inside the drain, but run concurrently, so
their order among themselves is not controlled.

A subject that takes an injected Combine `Scheduler` gets one from the capture, with no stamp:
`Scheduler` has associated types, so no protocol can paste it, and `context.scheduler(_:)` is the
double for that boundary.

```swift
.baselined { context in
    PhotoUploader(scheduler: context.scheduler(.main))   // or .serial("uploads"), .concurrent("thumbnails")
}
```

It holds work the way a stamped scheduling double does, and its time and option types are
`DispatchQueue`'s, so a project's type-erased scheduler takes it too (`AnySchedulerOf<DispatchQueue>`
through `eraseToAnyScheduler()`).

| Scheduler call | Under test |
| --- | --- |
| `schedule(options:_:)` | held, run in enqueue order, on the queue's domain; a `group` option holds the work in the group until it runs |
| `schedule(after:…)` | held on virtual time, recording a `timer` event with the delay it was handed |
| `schedule(after:interval:…)` | re-armed on virtual time until cancelled; one never cancelled stops at the backlog cap |
| `now` | the capture's virtual time, the same on every run |

Its clock is the reason to take it over a hand-written adapter. An adapter over a queue protocol whose
`now` reads the wall clock leaves `measureInterval`, `throttle` and `timeout` reading real time while
their work runs on virtual time: a baseline checked against itself comes back `UNSTABLE`. The audit
still names `import Combine` as the `Combine` channel.

### Settle points

Running every operation first and the held work last is one legal schedule: the most impatient user. A
port that only misbehaves once an earlier operation's work has landed would pass it. So when the golden
run holds work across a gap between operations, exploration also tries settle points. Each gap is held
(nothing runs), ready (what is ready now runs, the clock stays put) or elapsed (everything runs, timers
included). Each ordering runs under up to four settle schedules, all-held and all-elapsed first. Both
sides always run the same schedule, and a failing order shows it: `refresh → settle:elapsed → refresh`.

### Main-actor work

A capture's own frames run off the main thread, so anything on the main thread inside a capture is the
subject's doing and records on `main`: work handed to a `.main` queue protocol, a `@MainActor` method, a
held task that hops to the main actor. A port that drops a hop to main diverges with
`ran on a different domain (main → …)`.

For the same reason, operations must be nonisolated. An operation closure written in a `@MainActor`
context would run on main and make the subject's nonisolated code read as `main`, so a capture refuses
it and names the fix. Under default main-actor isolation, mark the spec type `nonisolated`. A subject's
isolated method is still reachable from a nonisolated operation with `await`.

## Haruspec overrides nothing

Haruspec does not redefine Grand Central Dispatch, swap your queues, or patch `Task`. A subject that
hands work off directly reaches a thread the capture neither holds nor waits for. The
capture-completeness audit reads the sources a verdict covered and flags these as the `dispatch`
channel: the `dispatch_async` family, `DispatchQueue(`, `DispatchQueue.main`, `DispatchQueue.global`,
`asyncAfter(`, `Task {`, `Task.detached`, `MainActor.run`, and operation-queue `addOperation` blocks.
Its other channels are `NotificationCenter.default` as a receiver, `Timer / RunLoop`, `Combine`, `KVO`
and `Core Data`.

The audit runs when `HARUSPEC_SOURCE_ROOT` names the checkout, or when a test calls `.audited()` on the
verdict. Otherwise every verdict says `blind spots: not audited`.

**When the audit flags dispatch,** the finding is a coverage gap: an otherwise-equivalent verdict reads
`CANNOT-VERIFY` with `blind spots: dispatch`, and a red stays red and carries it. To clear it, route
the hop through the subject's injected scheduling protocol: `mainQueue.async { … }` for
`DispatchQueue.main.async { … }`, `tasks.spawn { … }` for `Task { … }`, a `@MainActor` method for
`MainActor.run`. If the reach is real and you accept not seeing it, say so by name:
`.accepts(uncaptured: "dispatch")` on the spec, for a blind spot every candidate shares, or
`Accepts(uncaptured: "dispatch")` in one check's intent. It stays on the verdict as
`dispatch (declared)`, and a declared channel the audit no longer finds reads `(declared, not found)`.

## Never silently mock

Wherever Haruspec cannot control a seam, it says so in the verdict's own terms:

| What happened | What you get |
| --- | --- |
| A parameter nothing serves | the capture stops, naming the declaration to write |
| A replay reads past the recording | `CANNOT-VERIFY`, `unrecorded reach: <seam>` |
| A declared domain nothing read | `CANNOT-VERIFY`, `declared domain matched nothing: <seam>` |
| The audit finds an unrecorded channel | `CANNOT-VERIFY`, `blind spots: <channel>` |
| The subject makes up a value | `UNSTABLE`, naming the field |

A double is not a mock in this sense: it answers only with recorded, replayed, sweepable input, and the
calls made to it are part of what the diff compares.

## When a verdict says UNSTABLE

`UNSTABLE` means identical inputs produced different results, so no comparison can gate. A live check
reruns a failing input with the baseline on both sides, and a baseline that disagrees with itself reads
`UNSTABLE`. A plan replay runs three passes, and passes that disagree read `UNSTABLE`. Either way the
report names each payload field that varied, with its shape and the injection that controls it:

```text
🌀 UNSTABLE  …
  stability: the baseline disagreed with itself on the failing input:
  …
  uncontrolled seams — values the subject makes up itself:
    Total.orderID (UUID): a fresh identifier — inject its source (a `() -> UUID` the initializer takes, supplied by the spec's `.provides`)
```

To fix it, find where the named event's field is made (`Total`, `orderID`), take its source through the
initializer with the real one as the default, and provide it from the spec: a fixed source, or one read
through the seams.

An `UNSTABLE` with no named field usually means ordering: work on different domains interleaving
differently from run to run. If cross-domain order is not part of the contract, compare per domain with
`.comparing(Comparison(concurrency: .perDomain))`.

A value only the port makes up is the port's divergence, so it reads `DIVERGED`. When both sides of a
mismatch look minted (two identifiers, or two timestamps of one format), the divergence carries a hint:
`likely an uncontrolled seam: inject the identifier's source`, or `inject the clock`.

## See also

- [specs.md](specs.md): stamping a protocol, `Amend`, `.vary` and `check`.
- [verdicts.md](verdicts.md): the four verdicts, the qualification block, and declaring intent.
- [../README.md](../README.md): what Haruspec is, and how to start.
