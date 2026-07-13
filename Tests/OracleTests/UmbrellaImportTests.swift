import XCTest
import Oracle   // ← the ONE import. No OracleCore / OracleTrace / OracleMacros / OracleSeams / OracleScenario.

// ─────────────────────────────────────────────────────────────────────────────────────────────
// The consumer's-eye view. This target links only the `Oracle` umbrella, so everything below is
// reachable *solely* because `import Oracle` re-exports it. If any re-export were missing this file
// would not compile — which is the test. It deliberately touches one symbol from each module:
//
//   OracleMacros   — @Traced, @Timed, @Seamed
//   OracleTrace    — Oracle.marker / Oracle.interval, TraceRecorder, NotificationInterceptor, ManualClock
//   OracleCore     — ToleranceSpec, TraceDiff.Verdict
//   OracleSeams    — Cassette, OracleSeam, SeamClock, SeamDomain
//   OracleScenario — Scenario / Op / Seam / Ordering / .verify(against:)
//
// It is also the empirical proof of the name-collision decision: this file calls both
// `Oracle.marker(...)` (the re-exported `enum Oracle` from OracleTrace) AND uses the `Scenario`
// types, under a lone `import Oracle`. Compiling clean confirms the module name and the type name
// coexist without ambiguity.
// ─────────────────────────────────────────────────────────────────────────────────────────────

protocol Cart: AnyObject {
    func add(cents: Int, qty: Int)
    func checkout() -> Int
}

/// Baseline. `@Traced` (OracleMacros) gives the structural tier for free; the notifications +
/// `Oracle.marker` (OracleTrace) give the durable semantic tier; `@Timed` times one method.
@Traced("Cart")
final class GoodCart: Cart {
    private let center: NotificationCenter
    private var subtotal = 0
    init(center: NotificationCenter) { self.center = center }

    func add(cents: Int, qty: Int) {
        subtotal += cents * qty
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }
    @Timed func checkout() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": subtotal])
        Oracle.marker("checkout_completed")   // ← `Oracle.marker` under `import Oracle`: the collision proof
        return subtotal
    }
}

/// A behavior-preserving refactor (different internal storage, identical observable behavior) →
/// the differential harness should call this EQUIVALENT to `GoodCart`.
@Traced("Cart")
final class RefactorCart: Cart {
    private let center: NotificationCenter
    private var lines: [(price: Int, qty: Int)] = []
    init(center: NotificationCenter) { self.center = center }
    private var subtotal: Int { lines.reduce(0) { $0 + $1.price * $1.qty } }

    func add(cents: Int, qty: Int) {
        lines.append((cents, qty))
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["subtotal": subtotal])
    }
    @Timed func checkout() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": subtotal])
        Oracle.marker("checkout_completed")
        return subtotal
    }
}

/// `@Seamed` (OracleMacros) routes un-injected nondeterminism through the ambient `OracleSeam`
/// cassette (OracleSeams). The rewrite it emits references OracleSeams symbols at *this* use site,
/// so it only resolves because `import Oracle` re-exports them.
@Seamed
final class LegacyClock {
    func stampMillis() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}

private func makeGood(_ ctx: SeamContext) -> Cart { GoodCart(center: ctx.notifications) }
private func makeRefactor(_ ctx: SeamContext) -> Cart { RefactorCart(center: ctx.notifications) }

final class UmbrellaImportTests: XCTestCase {

    /// The headline: the entire Scenario DSL + macros + verdict types are reachable through one import,
    /// end-to-end. Also exercises the seam-value and ordering variation builders.
    func testSingleImportSurfacesScenarioDSL() {
        let scenario = Scenario<Cart>("umbrella-cart")
            .system(makeGood)
            .operations {
                Op("add") { cart, seams in cart.add(cents: 999, qty: Int(seams.int("qty", default: 2))) }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .tolerate(.strict)                                    // ← ToleranceSpec (OracleCore)
            .vary { Ordering(max: 10); Seam("qty", .int(1...5)) } // ← Ordering / Seam / SeamDomain

        let verdict: ScenarioVerdict = scenario.verify(against: makeRefactor)
        let outcome: TraceDiff.Verdict = verdict.verdict          // ← TraceDiff.Verdict (OracleCore)
        XCTAssertEqual(outcome, .equivalent, "a behavior-preserving refactor is EQUIVALENT")
        XCTAssertTrue(verdict.diff.divergences.isEmpty)           // ← TraceDiff (OracleCore)
    }

    /// `htmlReport()` on all three verdict carriers is reachable through the single umbrella import —
    /// the visual companion to `report()`, self-contained enough to open over `file://`.
    func testHTMLReportIsReExported() throws {
        let verdict = Scenario<Cart>("umbrella-html")
            .system(makeGood)
            .operations { Op("checkout") { _ = $0.checkout() } }
            .observe(notifications: ["CheckoutCompleted"])
            .verify(against: makeRefactor)

        let scenarioHTML: String = verdict.htmlReport()           // ← ScenarioVerdict.htmlReport (OracleScenario)
        let diffHTML: String = verdict.diff.htmlReport()          // ← TraceDiff.htmlReport (OracleCore)
        let coverageHTML: String = VerificationResult(diff: verdict.diff, coverage: Coverage()).htmlReport()

        for html in [scenarioHTML, diffHTML, coverageHTML] {
            XCTAssertTrue(html.contains("<!doctype html>"))
            XCTAssertFalse(html.contains("https://"), "the report must be self-contained")
        }

        // The write-to-disk convenience (HTMLReporting.writeHTMLReport) is re-exported too — this is the
        // exact call the dogfood app makes in place of its old hand-rolled FileManager helper.
        let reportURL = verdict.writeHTMLReport(named: "umbrella-html")   // ← HTMLReporting (OracleCore)
        let url = try XCTUnwrap(reportURL)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), scenarioHTML)
    }

    /// The OracleTrace capture surface: recorder + interceptor + `@Traced`/`@Timed` bodies +
    /// `Oracle.interval` / `Oracle.marker`, all named through the umbrella.
    func testCaptureSurfaceIsReExported() {
        let recorder = TraceRecorder(name: "umbrella", clock: ManualClock())   // ← TraceRecorder + ManualClock
        let center = NotificationCenter()
        let interceptor = NotificationInterceptor(recorder: recorder, center: center,
                                                  names: ["CartChanged", "CheckoutCompleted"]) // ← NotificationInterceptor
        interceptor.start(); defer { interceptor.stop() }

        let cart = GoodCart(center: center)
        TraceContext.$current.withValue(recorder) {              // ← TraceContext (OracleTrace)
            Oracle.interval("session") {                         // ← `Oracle.interval` under `import Oracle`
                cart.add(cents: 500, qty: 3)
                _ = cart.checkout()
            }
        }
        let labels = recorder.trace().events.map(\.label)
        XCTAssertTrue(labels.contains("Cart.add"),             "@Traced recorded the structural tier")
        XCTAssertTrue(labels.contains("checkout_completed"),   "Oracle.marker recorded the semantic tier")
        XCTAssertTrue(labels.contains("CheckoutCompleted"),    "the interceptor captured the notification")
    }

    /// The OracleSeams surface: `Cassette` record→replay of a value seam, and `@Seamed` + `OracleSeam`
    /// binding of un-injected `Date()`.
    func testSeamHarnessIsReExported() {
        // A value seam: record once, replay returns the recorded reading (not the live one).
        let recording = Cassette()                                            // ← Cassette
        let recorded = SeamClock(cassette: recording, seam: "clock", live: { 1234.5 }).now()  // ← SeamClock
        let replayed = SeamClock(cassette: Cassette(replaying: recording.snapshot()),
                                 seam: "clock", live: { -1 }).now()
        XCTAssertEqual(replayed, recorded, "replay yields the recorded value, not the live one")

        // `@Seamed`: the rewritten bare `Date()` reads from the ambient cassette when one is bound.
        let clock = LegacyClock()
        let session = Cassette()
        let golden = OracleSeam.bind(session) { clock.stampMillis() }         // ← OracleSeam.bind
        let onReplay = OracleSeam.bind(Cassette(replaying: session.snapshot())) { clock.stampMillis() }
        XCTAssertEqual(onReplay, golden, "@Seamed-routed Date() replays identically through the cassette")
    }
}
