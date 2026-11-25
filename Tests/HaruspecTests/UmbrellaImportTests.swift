// ← the ONE import. No HaruspecCore / HaruspecTrace / HaruspecMacros / HaruspecSeams / HaruspecSpec.
import Haruspec
import XCTest

// ─────────────────────────────────────────────────────────────────────────────────────────────
// The consumer's-eye view. This target links only the `Haruspec` umbrella, so everything below is
// reachable *solely* because `import Haruspec` re-exports it. If any re-export were missing this file
// would not compile — which is the test. It deliberately touches one symbol from each module:
//
//   HaruspecMacros   — @Haruspec
//   HaruspecTrace    — Haruspec.marker / Haruspec.interval, TraceRecorder, RecordingNotificationCenter, ManualClock
//   HaruspecCore     — Comparison, TraceDiff.Verdict
//   HaruspecSeams    — Cassette, Seam, SeamClock, SeamDomain
//   HaruspecSpec — Spec / Op / Seam / Ordering / .baselined(on:)
//
// It is also the empirical proof of the name-collision decision: this file calls both
// `Haruspec.marker(...)` (the re-exported `enum Haruspec` from HaruspecTrace) AND uses the `Spec`
// types, under a lone `import Haruspec`. Compiling clean confirms the module name and the type name
// coexist without ambiguity.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// The stamp (HaruspecMacros) gives the structural tier for free: its forwarder records every call,
/// timed. Its expansion names HaruspecSpec symbols at *this* use site, so it only resolves because
/// `import Haruspec` re-exports them.
@Haruspec(timed: true)
protocol Cart: AnyObject {
    func add(cents: Int, qty: Int)
    func checkout() -> Int
}

/// Baseline. The notifications + ``Haruspec/marker`` (HaruspecTrace) give the durable semantic tier.
final class GoodCart: Cart {
    private let center: NotificationCenter
    private var subtotal = 0
    init(center: NotificationCenter) {
        self.center = center
    }

    func add(cents: Int, qty: Int) {
        subtotal += cents * qty
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }

    func checkout() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": subtotal])
        Haruspec.marker("checkout_completed") // ← `Haruspec.marker` under `import Haruspec`: the collision proof
        return subtotal
    }
}

/// A behavior-preserving refactor (different internal storage, identical observable behavior) →
/// the differential harness should call this EQUIVALENT to `GoodCart`.
final class RefactorCart: Cart {
    private let center: NotificationCenter
    private var lines: [(price: Int, qty: Int)] = []
    init(center: NotificationCenter) {
        self.center = center
    }

    func add(cents: Int, qty: Int) {
        lines.append((cents, qty))
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }

    func checkout() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": subtotal])
        Haruspec.marker("checkout_completed")
        return subtotal
    }

    private var subtotal: Int {
        lines.reduce(0) { $0 + $1.price * $1.qty }
    }
}

final class UmbrellaImportTests: XCTestCase {
    /// The headline: the entire Spec DSL + macros + verdict types are reachable through one import,
    /// end-to-end. Also exercises the seam-value and ordering variation builders.
    func testSingleImportSurfacesSpecDSL() async {
        let spec = Spec<Cart>("umbrella-cart")
            .operations {
                Op("add") { cart, seams in cart.add(cents: 999, qty: Int(seams.int("qty", default: 2))) }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .comparing(.strict) // ← Comparison (HaruspecCore)
            .vary { Ordering(max: 10); Seam("qty", .int(1 ... 5)) } // ← Ordering / Seam / SeamDomain
            .baselined(on: makeGood)

        let verdict: SpecVerdict = await spec.verify(candidate: makeRefactor)
        let outcome: TraceDiff.Verdict = verdict.verdict // ← TraceDiff.Verdict (HaruspecCore)
        XCTAssertEqual(outcome, .equivalent, "a behavior-preserving refactor is EQUIVALENT")
        XCTAssertTrue(verdict.diff.divergences.isEmpty) // ← TraceDiff (HaruspecCore)
    }

    /// ``HTMLReporting/htmlReport()`` on all three verdict carriers is reachable through the single umbrella import —
    /// the visual companion to ``SpecVerdict/report()``, self-contained enough to open over `file://`.
    func testHTMLReportIsReExported() async throws {
        let verdict = await Spec<Cart>("umbrella-html")
            .operations { Op("checkout") { _ = $0.checkout() } }
            .baselined(on: makeGood)
            .verify(candidate: makeRefactor)

        let scenarioHTML: String = verdict.htmlReport() // ← SpecVerdict.htmlReport (HaruspecSpec)
        let diffHTML: String = verdict.diff.htmlReport() // ← TraceDiff.htmlReport (HaruspecCore)
        let coverageHTML: String = VerificationResult(diff: verdict.diff, coverage: Coverage()).htmlReport()

        for html in [scenarioHTML, diffHTML, coverageHTML] {
            XCTAssertTrue(html.contains("<!doctype html>"))
            XCTAssertFalse(html.contains("https://"), "the report must be self-contained")
        }

        // The write-to-disk convenience (HTMLReporting.writeHTMLReport) is re-exported too — this is the
        // exact call the dogfood app makes in place of its old hand-rolled FileManager helper.
        let reportURL = verdict.writeHTMLReport(named: "umbrella-html") // ← HTMLReporting (HaruspecCore)
        let url = try XCTUnwrap(reportURL)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), scenarioHTML)
    }

    /// The HaruspecTrace capture surface: recorder + interceptor + the forwarder's timed bodies +
    /// ``Haruspec/interval`` / ``Haruspec/marker``, all named through the umbrella.
    func testCaptureSurfaceIsReExported() {
        let recorder = TraceRecorder(name: "umbrella", clock: ManualClock()) // ← TraceRecorder + ManualClock
        let center = RecordingNotificationCenter()

        let cart = TracedCart(GoodCart(center: center))
        TraceContext.$current.withValue(recorder) { // ← TraceContext (HaruspecTrace)
            Haruspec.interval("session") { // ← `Haruspec.interval` under `import Haruspec`
                cart.add(cents: 500, qty: 3)
                _ = cart.checkout()
            }
        }
        let labels = recorder.trace().events.map(\.label)
        XCTAssertTrue(labels.contains("Cart.add"), "the forwarder recorded the structural tier")
        XCTAssertTrue(labels.contains("checkout_completed"), "Haruspec.marker recorded the semantic tier")
        XCTAssertTrue(labels.contains("CheckoutCompleted"), "the interceptor captured the notification")
    }

    /// The HaruspecSeams surface: `Cassette` record→replay of a value seam.
    func testSeamHarnessIsReExported() {
        // A value seam: record once, replay returns the recorded reading (not the live one).
        let recording = Cassette() // ← Cassette
        let recorded = SeamClock(cassette: recording, seam: "clock", live: { 1234.5 }).now() // ← SeamClock
        let replayed = SeamClock(
            cassette: Cassette(replaying: recording.snapshot()),
            seam: "clock",
            live: { -1 }
        ).now()
        XCTAssertEqual(replayed, recorded, "replay yields the recorded value, not the live one")
    }
}

private func makeGood(_ ctx: SeamContext) -> Cart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> Cart {
    RefactorCart(center: ctx.notifications)
}
