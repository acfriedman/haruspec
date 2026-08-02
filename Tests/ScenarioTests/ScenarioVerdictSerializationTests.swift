import Foundation
import HaruspecCore
import HaruspecScenario
import HaruspecSeams
import XCTest

// The verdict artifact (result.json) is what crosses the process boundary: written inside the test run
// that replayed the plan, read by `haruspec report` for rendering and the CI exit-code gate. These
// tests pin the file helpers (round-trip, canonical determinism), back-compat with pre-helper
// artifacts, and the committed fixture the CLI smoke test renders.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRoundBug(_ ctx: SeamContext) -> PromoCart {
    RoundBugCart(center: ctx.notifications)
}

final class ScenarioVerdictSerializationTests: XCTestCase {
    private func cart(system: @escaping (SeamContext) -> PromoCart) -> Scenario<PromoCart> {
        Scenario<PromoCart>("promo-cart.artifact")
            .system(system)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted", "LoyaltyPointsEarned"])
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 10)
            }
    }

    private func divergedVerdict() -> ScenarioVerdict {
        let plan = cart(system: makeGood).record()
        let verdict = cart(system: makeRoundBug).verify(replaying: plan)
        XCTAssertEqual(verdict.verdict, .diverged, "the fixture verdict must be a real caught regression")
        return verdict
    }

    private func artifactURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    func testResultArtifactRoundTripsThroughFileHelpers() throws {
        let verdict = divergedVerdict()
        let url = artifactURL("result")
        defer { try? FileManager.default.removeItem(at: url) }

        try verdict.write(to: url)
        let reloaded = try ScenarioVerdict(contentsOf: url)

        // No Equatable on ScenarioVerdict — compare the fields the report/gate actually consume.
        XCTAssertEqual(reloaded.verdict, verdict.verdict)
        XCTAssertEqual(reloaded.diff.divergences, verdict.diff.divergences)
        XCTAssertEqual(reloaded.counterexample, verdict.counterexample)
        XCTAssertEqual(reloaded.orderingsExplored, verdict.orderingsExplored)
        XCTAssertEqual(reloaded.failingOrder, verdict.failingOrder)
        XCTAssertEqual(reloaded.coverage, verdict.coverage)
    }

    func testCanonicalEncodingIsDeterministic() throws {
        let verdict = divergedVerdict()
        XCTAssertEqual(
            try verdict.jsonData(),
            try verdict.jsonData(),
            "identical verdicts must serialize to identical bytes — artifact diffs mean verdict diffs"
        )
    }

    func testHandRolledEncoderArtifactStillDecodes() throws {
        // Before the helpers existed, callers wrote result.json with a bare JSONEncoder. Those
        // artifacts must stay readable — same fields, different formatting.
        let verdict = divergedVerdict()
        let legacy = try JSONEncoder().encode(verdict)
        let reloaded = try ScenarioVerdict(jsonData: legacy)
        XCTAssertEqual(reloaded.verdict, verdict.verdict)
        XCTAssertEqual(reloaded.diff.divergences, verdict.diff.divergences)
    }

    // MARK: - The committed fixture (what the CLI smoke test renders)

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/diverged.result.json")
    }

    func testCommittedFixtureStillDecodes() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "diverged.result", withExtension: "json", subdirectory: "Fixtures"),
            "the committed fixture must ship with the test bundle"
        )
        let verdict = try ScenarioVerdict(contentsOf: fixture)
        XCTAssertEqual(verdict.verdict, .diverged, "schema drift check: the artifact shape still decodes")
        XCTAssertFalse(verdict.diff.divergences.isEmpty)
        XCTAssertNotNil(verdict.counterexample)
    }

    func testRegenerateCommittedFixture() throws {
        // Snapshot refresh, not a test: HARUSPEC_REGENERATE_FIXTURES=1 rewrites the committed
        // artifact after an intentional schema change. Skipped on normal runs.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARUSPEC_REGENERATE_FIXTURES"] == "1",
            "set HARUSPEC_REGENERATE_FIXTURES=1 to rewrite Fixtures/diverged.result.json"
        )
        try FileManager.default.createDirectory(
            at: fixtureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try divergedVerdict().write(to: fixtureURL)
    }
}
