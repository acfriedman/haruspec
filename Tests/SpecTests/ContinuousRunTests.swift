import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// The CI harness over record/replay: that the environment contract is honored exactly (a selected mode
// with a missing destination is a hard failure, an absent mode disables the suite), and that each side
// writes the artifacts CI gates on with a `succeeded` that tracks the verdict.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRoundBug(_ ctx: SeamContext) -> PromoCart {
    RoundBugCart(center: ctx.notifications)
}

final class ContinuousRunTests: XCTestCase {
    private func cart(system: @escaping (SeamContext) -> PromoCart) -> Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.continuous")
            .system(system)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 4)
            }
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("continuous-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Environment contract

    func testAbsentOrUnrecognizedModeDisablesTheSuite() throws {
        XCTAssertNil(ContinuousMode.fromEnvironment([:]))
        XCTAssertNil(ContinuousMode.fromEnvironment(["HARUSPEC_MODE": "dry-run"]))
        XCTAssertNil(try ContinuousRun.fromEnvironment([:]))
    }

    func testSelectedModeWithoutItsDestinationsThrows() {
        XCTAssertThrowsError(try ContinuousRun.fromEnvironment(["HARUSPEC_MODE": "record"]))
        // Present-but-empty is the same failure as missing: never defaulted.
        XCTAssertThrowsError(try ContinuousRun.fromEnvironment([
            "HARUSPEC_MODE": "record",
            "HARUSPEC_PLAN_PATH": ""
        ]))
        XCTAssertThrowsError(try ContinuousRun.fromEnvironment([
            "HARUSPEC_MODE": "replay",
            "HARUSPEC_PLAN_PATH": "/tmp/plan.json"
        ]))
    }

    func testEachModeParsesIntoItsOwnDestinations() throws {
        let recording = try ContinuousRun.fromEnvironment([
            "HARUSPEC_MODE": "record",
            "HARUSPEC_PLAN_PATH": "/tmp/plan.json"
        ])
        guard case let .record(planURL) = recording else {
            return XCTFail("expected a record run, got \(String(describing: recording))")
        }
        XCTAssertEqual(planURL.path, "/tmp/plan.json")

        let replaying = try ContinuousRun.fromEnvironment([
            "HARUSPEC_MODE": "replay",
            "HARUSPEC_PLAN_PATH": "/tmp/plan.json",
            "HARUSPEC_RESULTS_DIR": "/tmp/results"
        ])
        guard case let .replay(plan, results) = replaying else {
            return XCTFail("expected a replay run, got \(String(describing: replaying))")
        }
        XCTAssertEqual(plan.path, "/tmp/plan.json")
        XCTAssertEqual(results.path, "/tmp/results")
    }

    // MARK: Record

    func testRecordCreatesMissingDirectoriesAndWritesThePlan() async throws {
        let planURL = scratch().appendingPathComponent("nested/plan.json")
        let outcome = await cart(system: makeGood).runContinuous(.record(planURL: planURL))

        XCTAssertTrue(outcome.succeeded, outcome.summary)
        XCTAssertEqual(outcome.artifactPath, planURL.path)
        XCTAssertNil(outcome.htmlReportPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planURL.path))
        XCTAssertNoThrow(try SpecPlan(contentsOf: planURL))
    }

    // MARK: Replay

    func testReplayOfAFaithfulBuildWritesAnEquivalentVerdict() async throws {
        let planURL = scratch().appendingPathComponent("plan.json")
        let resultsDir = scratch()
        let recorded = await cart(system: makeGood).runContinuous(.record(planURL: planURL))
        XCTAssertTrue(recorded.succeeded)

        let outcome = await cart(system: makeGood)
            .runContinuous(.replay(planURL: planURL, resultsDirectory: resultsDir))

        XCTAssertTrue(outcome.succeeded, outcome.summary)
        let resultURL = resultsDir.appendingPathComponent("result.json")
        XCTAssertEqual(outcome.artifactPath, resultURL.path)
        XCTAssertEqual(try SpecVerdict(contentsOf: resultURL).verdict, .equivalent)
        // The visual report is named for the spec, alongside the verdict CI gates on.
        XCTAssertEqual(
            outcome.htmlReportPath,
            resultsDir.appendingPathComponent("promo-cart.continuous.html").path
        )
    }

    func testReplayOfARegressionFailsAndPinsTheDivergenceInResultJSON() async throws {
        let planURL = scratch().appendingPathComponent("plan.json")
        let resultsDir = scratch()
        let recorded = await cart(system: makeGood).runContinuous(.record(planURL: planURL))
        XCTAssertTrue(recorded.succeeded)

        let outcome = await cart(system: makeRoundBug)
            .runContinuous(.replay(planURL: planURL, resultsDirectory: resultsDir))

        XCTAssertFalse(outcome.succeeded)
        let verdict = try SpecVerdict(contentsOf: resultsDir.appendingPathComponent("result.json"))
        XCTAssertEqual(verdict.verdict, .diverged)
    }

    func testAMissingPlanIsReportedRatherThanThrown() async {
        let outcome = await cart(system: makeGood).runContinuous(
            .replay(planURL: scratch().appendingPathComponent("absent.json"), resultsDirectory: scratch())
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.summary.hasPrefix("replay failed:"), outcome.summary)
    }

    // MARK: Environment-driven entry point

    func testTheEnvironmentEntryPointDrivesTheSelectedSide() async {
        let planURL = scratch().appendingPathComponent("plan.json")
        let outcome = await cart(system: makeGood).runContinuous(environment: [
            "HARUSPEC_MODE": "record",
            "HARUSPEC_PLAN_PATH": planURL.path
        ])

        XCTAssertTrue(outcome.succeeded, outcome.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planURL.path))
    }

    func testAnUnselectedRunFailsLoudlyRatherThanPassingSilently() async {
        let outcome = await cart(system: makeGood).runContinuous(environment: [:])

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.summary.contains("HARUSPEC_MODE"), outcome.summary)
    }
}
