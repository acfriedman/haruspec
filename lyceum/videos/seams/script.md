---
title: "Seams: what the oracle controls"
status: draft 1
updated: 2026-10-11
# Written form → spoken form, applied only to the text sent to the voice.
pronounce: {}
# Subtitles: a track viewers turn on, or `captions: burned` to draw them into the picture.
# captions: burned
# The look: the dark canvas, or `theme: paper`, a light, formal look for presentations.
# theme: paper
# The files this video explains, one per line: `- path (what the video takes from it)`.
# `lyceum stale` watches them; `lyceum stale --mark seams` records the commit they were checked at.
sources:
  - docs/seams.md (the paired concept doc; same story, with the code detail)
  - README.md (the threads stamp on screen in scene 06; "Haruspec overrides nothing"; check resolves each initializer parameter)
  - Tests/SpecTests/StabilityTests.swift (MintingSubject posts a fresh UUID; the same class on both sides reads UNSTABLE and names Total.orderID)
  - Sources/Spec/UncontrolledSeam.swift (the remedy each value shape names: a fresh identifier, a clock reading)
  - Sources/Spec/Stability.swift (the unstable report lines: the baseline disagreed with itself; uncontrolled seams)
  - Sources/Spec/SystemResolution.swift (resolution order: a provided resource, the capture's center, the one stamped double, a packaged default; the trap naming the fix)
  - Sources/Spec/InitializerBuilds.swift (check(_:) by initializer resolves every parameter)
  - Sources/MacroPlugin/Double.swift (a double records each call and answers from the seam "<label>.<member>")
  - Sources/Spec/Spec.swift (SeamContext's typed reads; provides(_:_:))
  - Sources/Spec/SpecRunner.swift (the golden cassette is recorded from the baseline; each probe replays it into both sides)
  - Sources/Seams/Cassette.swift (record and replay; answers bound to arguments; a miss falls back to live, never fabricated)
  - Sources/Core/Coverage.swift (an unrecorded read downgrades EQUIVALENT to CANNOT-VERIFY)
  - Tests/SpecTests/SpecPlanTests.swift (a seam read past the recording abstains, naming surgeFactor)
  - Sources/Seams/ValueSeams (the ready-made value seams, each on a cassette you hold)
  - Sources/Seams/NetworkSeam.swift (CassetteURLProtocol, the network recorder)
  - Sources/Macros/Macros.swift (@Haruspec(schedules:) and the five requirement shapes)
  - Sources/MacroPlugin/Scheduler.swift (the scheduling double hands every enqueue to the backlog)
  - Sources/Trace/WorkBacklog.swift (held work runs one item at a time in enqueue order; Settle ready and elapsed)
  - Sources/Spec/SettlePoints.swift (a setting per gap: held, ready, elapsed)
  - Sources/Spec/SpecCapture.swift (settle steps between operations, the drain after them, captures run off main)
  - Tests/SpecTests/SchedulingStampTests.swift (the Depot queues; a port that announces off main diverges on its domain)
  - Tests/SpecTests/SettlePointTests.swift (a port that only breaks after an earlier refresh lands)
  - Sources/Trace/DomainResolver.swift (main-actor work records main inside a capture)
  - Sources/Core/DiffProjection.swift (the "ran on a different domain" wording)
  - Sources/Audit/ChannelLint.swift (the dispatch channel: direct GCD, Task {, MainActor.run)
  - Sources/Spec/SpecAudit.swift (an audit finding becomes a gap, so a green reads CANNOT-VERIFY)
  - example-xcode-migration/LegacyAppTests/SubjectBoundaries.swift (the Cart protocol's pasted init: collaborators, a queue, an ID source and a clock)
  - example-xcode-migration/LegacyAppTests/CartMigrationSpec.swift (provides sequential identifiers and a fixed instant)
  - example-xcode-migration/LegacyAppTests/Minted.swift (the sequential UUID source and the fixed instant)
  - example-xcode-migration/LegacyAppTests/FulfillmentMigrationSpec.swift (a clock read through the seam Clock.now, swept over eight instants)

# The one file this video explains.
explains: "docs/seams.md"
verified:
  ".": "b2f1975473ac"
  example-xcode-migration: "c177f1d3f947"
---

<!--
Format: one `## NN · id — Title` per scene. `> Visual:` lines describe the animation; every other
paragraph is narration, spoken in order. The narration is the only text sent to TTS, so it is
written for the ear: no identifiers that read badly aloud, short sentences. The intent above the
first scene is never narrated.
-->

# Intent

- **Point:** Haruspec can only compare what it controls. Everything that crosses the subject's
  boundary (collaborators, values, threads) comes in through the initializer, so the spec can hand
  both sides identical inputs; whatever it cannot control, it names (UNSTABLE, an audit finding,
  CANNOT-VERIFY) instead of mocking it.
- **Angle:** open on a subject compared with itself that still reads unstable, because it makes up
  an identifier. Frame the boundary and the one rule (through the initializer), then apply it to
  collaborators, values, the cassette that replays them, and threads. Close on what Haruspec refuses
  to do, and call back to the cold open fixed.
- **Length:** about 5 minutes (784 spoken words, 8 scenes).
- **Notes:**
  - Stay in the seams lane. The spec DSL appears only as the `.provides` and `Seam` lines a seam
    needs (point at the specs video); the qualification block and the four verdicts in full belong
    to the verdicts video. Verdict names appear as coloured banners only.
  - Colours: baseline blue, candidate pink; EQUIVALENT green, DIVERGED red, CANNOT-VERIFY amber,
    UNSTABLE violet. Copy `scenes/shared.tsx` from the first video built.
  - The ready-made value seams (`SeamClock`, `SeamRNG`, `SeamDefaults`, `SeamKeychain`,
    `SeamFileSystem`, `SeamEnvironment`, `CassetteURLProtocol`) record and replay through a
    `Cassette` the caller holds. A spec's capture does not hand out its cassette or bind the ambient
    one, so inside a spec a value is controlled with `.provides`. Scene 04 says "a harness you write
    yourself" for exactly that reason; don't imply they plug into a check.
  - An uncontrolled value only in the port reads DIVERGED (the port's divergence, with a "likely an
    uncontrolled seam" hint), not UNSTABLE. The video only claims UNSTABLE for a subject that
    disagrees with itself, which is what the cold open shows.
  - Dogfood sources (`example-xcode-migration/`) are used only where the engine has no equivalent:
    a pasted init spanning all three seam kinds, a spec that provides an identifier source, and a
    clock swept over named instants.

## 01 · cold-open — The same code disagrees

> Visual: Left: a `CodeCard` titled "StabilityTests.swift", labelled "reformatted" in the corner,
> showing the fixture's method (real, lines 71-73, the dictionary broken over lines):
> ```swift
> func total() {
>     center.post(
>         name: .init("Total"),
>         object: nil,
>         userInfo: ["value": 42, "orderID": UUID().uuidString]
>     )
> }
> ```
> Right: two boxes side by side, "baseline" in blue and "candidate" in pink, both captioned
> `MintingSubject`. On "the same class", the two captions pulse together. On "identical inputs", one
> grey bar labelled "identical inputs" splits into an arrow to each box. Beneath each box a payload
> chip: blue `value 42 · orderID 3F2C9A1E-…`, pink `value 42 · orderID 9B07D4C2-…` (illustrative
> UUIDs). On "unstable", a violet banner `🌀 UNSTABLE` drops across both boxes. On "on the spot",
> `UUID().uuidString` in the card glows violet. On "agree with itself", the pink box turns blue too
> (now baseline against baseline) and the two chips still differ. On "names the field", a report
> panel slides up, labelled "abridged" (real lines from Stability.swift and UncontrolledSeam.swift,
> asserted in StabilityTests.swift:269-287):
> ```text
> 🌀 UNSTABLE
>   stability: the baseline disagreed with itself on the failing input
>   uncontrolled seams — values the subject makes up itself:
>     Total.orderID (UUID): a fresh identifier — inject its source
>       (a `() -> UUID` the initializer takes, supplied by the spec's `.provides`)
> ```
> and `Total.orderID` glows violet.

Here is a check that should be boring. The baseline and the candidate are the same class. Same code,
identical inputs. Haruspec doesn't say equivalent. It says unstable.

Look at what the class posts: a total of forty-two, and an order identifier it makes up on the spot,
fresh every run. The baseline can't even agree with itself, so no comparison against it means
anything. Haruspec says so, and names the field.

## 02 · boundary — Draw a line around the subject

> Visual: The cold open shrinks away. Centre: two boxes, "old code" in blue and "new code" in pink,
> each with a diff arrow into a small "diff" box between them. On "the same world", a single globe
> icon above feeds both boxes with one line. Then the scene zooms on the blue box: a dashed outline
> draws around it, labelled "the subject's boundary". On "collaborators, values, threads", three
> arrows cross the dashed line from the left, each writing on with its label as spoken
> ("collaborators", "values", "threads"); where each arrow crosses the line, a small gold notch
> appears labelled "seam". On "controls each one", the three arrows turn solid gold and an identical
> set appears on the pink box's boundary, with a caption "identical inputs". On "leaks in around the
> line", a grey squiggle from a cloud labelled "the world" bypasses the notches and enters the blue
> box directly; a differently shaped squiggle enters the pink box. On "not your change", the diff box
> between them flashes a question mark.

That's what this video is about. Haruspec drives the old code and the new code, and diffs what they
did. A difference only means something if both sides were handed the same world.

So draw a line around the subject. Everything that crosses it is a seam: collaborators, values,
threads. Haruspec controls each one, so both sides get identical inputs. When the world leaks in
around the line, the two sides see different worlds, and a difference might be the world, not your
change.

## 03 · initializer — Through the initializer

> Visual: Left: a `CodeCard` titled "SubjectBoundaries.swift" (dogfood app), labelled "abridged"
> (real, lines 32-51, the method and property requirements elided):
> ```swift
> @Haruspec
> protocol Cart: AnyObject {
>     init(
>         inventory: InventoryReserving,
>         analytics: AnalyticsTracking,
>         notificationCenter: NotificationCenter,
>         orderArchive: OrderArchiving,
>         stateQueue: SerialQueueing,
>         newOrderID: @escaping () -> UUID,
>         clock: @escaping () -> Date
>     )
>     …
> }
> ```
> On "its collaborators", `inventory`, `analytics` and `orderArchive` underline gold; on "a
> notification center", `notificationCenter`; on "a queue", `stateQueue`; on "order identifiers" and
> "its clock", `newOrderID` and `clock`. Right: a three-rung ladder writes on as spoken, top to bottom:
> "1 · what the spec provides", "2 · the capture's notification center", "3 · the one stamped double
> serving that type". On "the one stamped double", a box `DoubleInventory` appears beside the ladder,
> joined to `inventory` by a line, captioned `@Haruspec protocol Inventory: InventoryReserving`. On
> "records each call", a row `call Inventory.reserve` drops from it into a short blue trace strip. On
> "generated input", a chip `Inventory.stock → 0` pops out of the double. On "stops", the ladder
> greys out and a red-bordered message types in, labelled "abridged" (wording from
> SystemResolution.swift:222-226, type name from the card):
> ```text
> nothing serves OrderArchiving — declare it: paste its protocol under
> @Haruspec("<label>") refining OrderArchiving, provide it as a capture
> resource: .provides(OrderArchiving.self) { context in … }, or author
> the wiring: .baselined { context in … }
> ```
> On "never guesses", the message's first line underlines red.

The rule that makes this work is plain. A subject takes what it depends on through its initializer.
Here's a real cart's: its collaborators, a notification center, a queue, even where its order
identifiers and its clock come from.

When a check builds the cart, or your port, it fills every parameter the same way. First, anything
the spec provides. Then the notification center the capture records. Then the one stamped double
serving that type. A double records each call made to it, and answers with generated input instead
of doing real work. If nothing serves a parameter, the check stops and names the declaration to
write. It never guesses.

## 04 · values — Values from the world

> Visual: A grid of eight chips writes on, one per item as spoken: "clock", "fresh identifier",
> "random numbers", "user defaults", "keychain", "file", "locale", "network response". On "reads from
> the world", each chip draws a thin grey line out to a cloud labelled "the world". On "through the
> initializer", the Cart init card from scene 03 returns small at the top left with `newOrderID` and
> `clock` lit, and the cloud lines for "fresh identifier" and "clock" re-route into those two
> parameters. Centre: a `CodeCard` titled "CartMigrationSpec.swift" (dogfood app; real, lines 48-50):
> ```swift
> // A receipt's order ID and timestamp, held still per capture.
> .provides((() -> UUID).self) { _ in Minted.identifiers() }
> .provides((() -> Date).self) { _ in { Minted.instant } }
> ```
> On "sequential identifiers", a chip `00000000-0000-0000-0000-000000000001` flows to a blue box and a
> pink box together; on "one fixed instant", a chip `2026-09-21T14:13:20Z` (Minted.instant,
> 1,790,000,000 seconds) does the same. On "reads through the spec's seams", a second card slides in
> below, titled "FulfillmentMigrationSpec.swift" (dogfood app; real, lines 45 and 53, with a `…`
> between):
> ```swift
> .provides((() -> Date).self) { context in { StoreClock.now(context) } }
> …
> Seam("Clock.now", .oneOf(StoreClock.instants))
> ```
> On "eight instants", eight small date chips fan out from `Clock.now` (from StoreClock.instants, e.g.
> `2026-10-03T16:00:00Z` "Saturday", `2026-12-24T22:00:00Z` "Christmas Eve"); on "a Saturday" and "two
> holidays", those chips light. On "a harness you write yourself", a footer row writes on in a muted
> tone: `SeamClock · SeamRNG · SeamDefaults · SeamKeychain · SeamFileSystem · SeamEnvironment ·
> CassetteURLProtocol`, captioned "HaruspecSeams · on a Cassette you hold".

Values are seams too. The clock. A fresh identifier. Random numbers, user defaults, the keychain, a
file, the locale, a network response. Each is something your code reads from the world.

The fix is the same shape every time: take the source through the initializer, and let the spec
provide it. This cart's spec hands both sides sequential identifiers and one fixed instant. Or
provide a source that reads through the spec's seams. Then the value is recorded, replayed, and
swept: this planner's clock visits eight instants, across cutoffs, a Saturday and two holidays.

For a harness you write yourself, Haruspec also ships ready-made recorders for the common ones.

## 05 · cassette — Record once, replay into both

> Visual: Centre: a gold cassette with two labelled tracks (illustrative values; seam keys and the
> qualified-key format from Cassette.swift and FulfillmentMigrationSpec.swift): `Clock.now` and
> `Inventory.stock`. On "the baseline runs first", a blue box at the left lights with a red "record"
> dot; on "each reading, in order", values drop into the tracks one at a time: `2026-10-02T13:00:00Z`
> on `Clock.now`, then `3` and `0` on `Inventory.stock`, each stock value tagged with the question that
> drew it, `[sku="MUG"]` and `[sku="BEANS"]`. On "replayed into both sides", the cassette duplicates
> and one copy slides under the blue box, one under a pink box at the right; both show a green "play"
> glyph. On "the same questions in a different order", the pink box asks `stock(sku: "BEANS")` first,
> then `stock(sku: "MUG")`; each question draws a line to the value with its tag and gets back what the
> baseline got (`0`, then `3`). On "past the end", the pink box asks a fourth question with no track
> behind it; the line reaches empty tape and turns amber, a small "live" cloud answers instead, and an
> amber banner `⚠️ CANNOT-VERIFY` appears with one report line beneath it (the real line format from
> SpecTerminalReport.swift, seam name from SpecPlanTests.swift:246-258):
> `⚠︎ unrecorded reach: surgeFactor (replay fell back to live)`. On "names the seam", `surgeFactor`
> glows amber.

Every seam read lands on a cassette. The baseline runs first and records each reading, in order.
Then the cassette is replayed into both sides, so the baseline and the candidate are answered
identically. A double is answered by its arguments, so a port that asks the same questions in a
different order still gets the same answers.

What if the candidate reads past the end of the recording? Haruspec won't invent a value. It falls
back to the live one, and refuses to call the run equivalent. The verdict is cannot verify, and it
names the seam.

## 06 · threads — Threads are collaborators

> Visual: Left: a `CodeCard` titled "README.md" (real):
> ```swift
> @Haruspec(schedules: .serial)
> protocol StateQueue: SerialQueueing {
>     func async(_ work: @escaping () -> Void)   // held, run in order
>     func sync(_ work: () -> Void)              // the queue's held work, then inline
> }
> ```
> On "a real dispatch queue", a small box "production: DispatchQueue" appears above the card. On
> "serial, concurrent, or main", `.serial` in the card glows and two ghost alternatives (`.concurrent`,
> `.main`) flick beside it. Right: a timeline of operations `refresh`, `refresh`, `checkout` as pills.
> On "holds every piece of work", blocks peel off each pill into a tray labelled "held", numbered 1,
> 2, 3 in enqueue order. On "after the operations", the tray empties left to right into a blue trace
> strip after the last pill, in order 1, 2, 3. On "settle points", the gaps between pills each get a
> small three-way dial: "held", "ready", "elapsed"; on "as if the user paused", the first dial turns to
> "elapsed" and block 1 lands in that gap instead of at the end, the timeline reading
> `refresh → settle:elapsed → refresh`. On "after an earlier refresh has landed", a pink port's strip
> beside it shows its second `refresh` doing nothing and a red `❌ DIVERGED` tag (illustrative, after
> SettlePointTests.swift's StuckSettleFeed). On "main thread", a `.main` stamp and an event chip
> `ParcelDidPost · main` in blue. On "drops its hop to main", the pink counterpart's chip reads
> `ParcelDidPost · queue(serial):DepotQueue`, and a red line types in, labelled "reconstructed from
> SchedulingStampTests.swift:231-235 and DiffProjection.swift:294":
> `≠ ParcelDidPost: ran on a different domain (main → queue(serial):DepotQueue)`.

Threads are collaborators too. A subject that hands work to a queue takes that queue in its
initializer. Production passes a real dispatch queue. The test target stamps the protocol with the
discipline it honors: serial, concurrent, or main.

Under test, the stamped double holds every piece of work it's handed. The capture runs it after the
operations, one item at a time, in enqueue order, the same way every run. Between operations it also
explores settle points, where held work lands as if the user paused. So a port that only breaks after
an earlier refresh has landed still gets caught.

Work handed to the main queue runs on the main thread, and main actor code records as main wherever
it runs. A port that quietly drops its hop to main diverges, and the report names where the work
went.

## 07 · overrides-nothing — Haruspec overrides nothing

> Visual: Header: "Haruspec overrides nothing". On "redefine Grand Central Dispatch or patch your
> tasks", two struck-through grey labels: "redefine dispatch_async" and "patch Task". Then a column of
> three code chips at the left, writing on as spoken: `DispatchQueue.main.async { … }`, `Task { … }`,
> `await MainActor.run { … }`. On "the audit reads your source", a magnifier passes over them and an
> amber tag `dispatch` attaches to all three (the dispatch channel, ChannelLint.swift:90-115). On "a
> green with that finding", a green `✅ EQUIVALENT` banner flips to amber `⚠️ CANNOT-VERIFY` with a
> line `blind spots: dispatch`. Then three summary rows write on, each a cause and the verdict it
> earns: on "makes up", `UUID()` · `Date()` → violet `🌀 UNSTABLE` "names the field"; on "a read past
> the recording", `unrecorded reach` → amber `⚠️ CANNOT-VERIFY`; the dispatch row from above settles in
> as the third. On "never silently mocks", a header over the rows: "never silently mocked".

Notice what Haruspec doesn't do. It overrides nothing. It doesn't redefine Grand Central Dispatch or
patch your tasks. So a subject that dispatches directly, spawns a bare task, or calls main actor run
is outside the seams. The audit reads your source and names it: dispatch. A green with that finding
becomes cannot verify.

The same honesty holds everywhere. A value the subject makes up reads unstable, and names the field.
A read past the recording reads cannot verify. Haruspec never silently mocks a seam it doesn't
control. It tells you which one, and what to inject.

## 08 · recap — One world

> Visual: The cold open's two boxes and `CodeCard` return, the card now labelled "simplified":
> ```swift
> init(center: NotificationCenter, newOrderID: @escaping () -> UUID)
> …
> userInfo: ["value": 42, "orderID": newOrderID().uuidString]
> ```
> On "through the initializer", the `newOrderID` parameter writes in. On "provide sequential
> identifiers", the real `.provides((() -> UUID).self) { _ in Minted.identifiers() }` line from scene 04
> slides under the card. Both payload chips change to `orderID 00000000-…-000000000001`. On "reads
> equivalent", the violet banner flips to green `✅ EQUIVALENT`. On "That's the discipline", the boxes
> fade and three lines write on: "collaborators → the initializer", "values → provided by the spec",
> "threads → a stamped queue". On "watch specs" and "watch verdicts", two end cards: "specs: write the
> spec" and "verdicts: read the verdict", with `docs/seams.md` beneath.

Back to the subject that couldn't agree with itself. Take the identifier's source through the
initializer, provide sequential identifiers, and both sides draw the same ones. The baseline
reproduces itself, and the check reads equivalent.

That's the discipline. Collaborators, values and threads come in through the initializer, and the
spec controls them, so both sides see one world. To write the spec, watch specs. To read every line
of a verdict, watch verdicts.
