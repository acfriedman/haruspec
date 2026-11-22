import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

final class SpecVerdictSerializationTests: XCTestCase {
    func testResultArtifactRoundTripsThroughFileHelpers() async throws {
        let verdict = await divergedVerdict()
        let url = artifactURL("result")
        defer { try? FileManager.default.removeItem(at: url) }

        try verdict.write(to: url)
        let reloaded = try SpecVerdict(contentsOf: url)

        // No Equatable on SpecVerdict — compare the fields the report/gate actually consume.
        XCTAssertEqual(reloaded.verdict, verdict.verdict)
        XCTAssertEqual(reloaded.diff.divergences, verdict.diff.divergences)
        XCTAssertEqual(reloaded.counterexample, verdict.counterexample)
        XCTAssertEqual(reloaded.orderingsExplored, verdict.orderingsExplored)
        XCTAssertEqual(reloaded.failingOrder, verdict.failingOrder)
        XCTAssertEqual(reloaded.coverage, verdict.coverage)
    }

    private func artifactURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    func testCanonicalEncodingIsDeterministic() async throws {
        let verdict = await divergedVerdict()
        XCTAssertEqual(
            try verdict.jsonData(),
            try verdict.jsonData(),
            "identical verdicts must serialize to identical bytes — artifact diffs mean verdict diffs"
        )
    }

    func testHandRolledEncoderArtifactStillDecodes() async throws {
        // Before the helpers existed, callers wrote result.json with a bare JSONEncoder. Those
        // artifacts must stay readable — same fields, different formatting.
        let verdict = await divergedVerdict()
        let legacy = try JSONEncoder().encode(verdict)
        let reloaded = try SpecVerdict(jsonData: legacy)
        XCTAssertEqual(reloaded.verdict, verdict.verdict)
        XCTAssertEqual(reloaded.diff.divergences, verdict.diff.divergences)
    }

    private func divergedVerdict() async -> SpecVerdict {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeRoundBug).verify(replaying: plan)
        XCTAssertEqual(verdict.verdict, .diverged, "the fixture verdict must be a real caught regression")
        return verdict
    }

    private func cart(system: @escaping (SeamContext) -> PromoCart) -> BaselinedSpec<PromoCart> {
        Spec<PromoCart>("promo-cart.artifact")
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 10)
            }
            .baselined(on: system)
    }

    // MARK: - The committed fixture (what the CLI smoke test renders)

    func testCommittedFixtureStillDecodes() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "diverged.result", withExtension: "json", subdirectory: "Fixtures"),
            "the committed fixture must ship with the test bundle"
        )
        let verdict = try SpecVerdict(contentsOf: fixture)
        XCTAssertEqual(verdict.verdict, .diverged, "schema drift check: the artifact shape still decodes")
        XCTAssertFalse(verdict.diff.divergences.isEmpty)
        XCTAssertNotNil(verdict.counterexample)
    }

    func testRegenerateCommittedFixture() async throws {
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
        try await divergedVerdict().write(to: fixtureURL)
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/diverged.result.json")
    }
}

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
