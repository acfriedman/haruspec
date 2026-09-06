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
        guard case let .replay(plan, results, intent) = replaying else {
            return XCTFail("expected a replay run, got \(String(describing: replaying))")
        }
        XCTAssertEqual(plan.path, "/tmp/plan.json")
        XCTAssertEqual(results.path, "/tmp/results")
        XCTAssertNil(intent)
    }

    func testReplayEnvironmentCarriesAnIntentPath() throws {
        let replaying = try ContinuousRun.fromEnvironment([
            "HARUSPEC_MODE": "replay",
            "HARUSPEC_PLAN_PATH": "/tmp/plans/search.combine.plan.json.gz",
            "HARUSPEC_RESULTS_DIR": "/tmp/results",
            "HARUSPEC_INTENT_PATH": "/tmp/intent/search.combine.intent.json"
        ])
        guard case let .replay(_, _, intent) = replaying else {
            return XCTFail("expected a replay run, got \(String(describing: replaying))")
        }
        XCTAssertEqual(intent?.path, "/tmp/intent/search.combine.intent.json")
    }

    func testAnIntentOnTheRecordSideIsRefused() {
        XCTAssertThrowsError(try ContinuousRun.fromEnvironment([
            "HARUSPEC_MODE": "record",
            "HARUSPEC_PLAN_PATH": "/tmp/plan.json",
            "HARUSPEC_INTENT_PATH": "/tmp/intent.json"
        ])) { error in
            XCTAssertTrue("\(error)".contains("record run is the baseline"), "\(error)")
        }
    }

    func testAMispairedIntentStemIsRefused() {
        XCTAssertThrowsError(try ContinuousRun.fromEnvironment([
            "HARUSPEC_MODE": "replay",
            "HARUSPEC_PLAN_PATH": "/tmp/plans/cart.objc-to-swift.plan.json.gz",
            "HARUSPEC_RESULTS_DIR": "/tmp/results",
            "HARUSPEC_INTENT_PATH": "/tmp/intent/search.combine.intent.json"
        ])) { error in
            XCTAssertTrue("\(error)".contains("search.combine"), "\(error)")
            XCTAssertTrue("\(error)".contains("cart.objc-to-swift"), "\(error)")
        }
    }

    func testIntentStemMatchesViaSpecNameHelper() {
        XCTAssertEqual(ContinuousRun.specName(inIntentPath: "/a/search.combine.intent.json"), "search.combine")
        XCTAssertNil(ContinuousRun.specName(inIntentPath: "/a/free-form.json"))
        XCTAssertNil(ContinuousRun.specName(inIntentPath: "/a/.intent.json"))
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
            .runContinuous(.replay(planURL: planURL, resultsDirectory: resultsDir, intentURL: nil))

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
            .runContinuous(.replay(planURL: planURL, resultsDirectory: resultsDir, intentURL: nil))

        XCTAssertFalse(outcome.succeeded)
        let verdict = try SpecVerdict(contentsOf: resultsDir.appendingPathComponent("result.json"))
        XCTAssertEqual(verdict.verdict, .diverged)
    }

    // MARK: Intent (extension mode)

    /// The whole signaling loop, engine-side: a red replay's own suggested declarations, parsed
    /// back through the grammar, turn the re-run green with the divergences disclosed as intended.
    ///
    /// And with no dead declaration left over — the suggestions are exactly as wide as what was seen.
    func testSuggestedDeclarationsTurnAChangedBuildGreenWithDisclosure() async throws {
        let planURL = scratch().appendingPathComponent("promo-cart.continuous.plan.json")
        _ = await cart(system: makeGood).runContinuous(.record(planURL: planURL))

        // Iterative inventory: a red replay stops at its first divergent probe, so declaring what it
        // showed can surface further divergences on the next run — accumulate until green.
        var intentText = ""
        for _ in 0 ..< 5 {
            let intent = try IntentGrammar.intent(parsing: intentText)
            let verdict = try await cart(system: makeRoundBug)
                .verify(replayingContentsOf: planURL, declaring: intent)
            if verdict.verdict == .equivalent {
                XCTAssertGreaterThan(verdict.diff.intendedCount, 0, "green must come from absorption")
                XCTAssertEqual(verdict.diff.unobservedIntent, [], "no declaration may be dead")
                return
            }
            let suggested = verdict.diff.divergences.compactMap(\.suggestedDeclaration)
            XCTAssertFalse(suggested.isEmpty, "a gating divergence must offer its declaration")
            intentText += "\n" + suggested.joined(separator: "\n")
        }
        XCTFail("the suggested declarations never turned the replay green")
    }

    /// The exit-6 side: a declaration the whole sweep never observes fails the run even though
    /// behavior matched — a dead declaration is a standing excuse, not a no-op.
    func testAnUnobservedDeclarationFailsAnOtherwiseGreenReplay() async throws {
        let planURL = scratch().appendingPathComponent("promo-cart.continuous.plan.json")
        let resultsDir = scratch()
        _ = await cart(system: makeGood).runContinuous(.record(planURL: planURL))

        let intentURL = scratch().appendingPathComponent("promo-cart.continuous.intent.json")
        try FileManager.default.createDirectory(
            at: intentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(Intent(expectedNewEvents: ["NeverEmitted"])).write(to: intentURL)

        let outcome = await cart(system: makeGood)
            .runContinuous(.replay(planURL: planURL, resultsDirectory: resultsDir, intentURL: intentURL))

        XCTAssertFalse(outcome.succeeded, "a dead declaration must fail the continuous run")
        let verdict = try SpecVerdict(contentsOf: resultsDir.appendingPathComponent("result.json"))
        XCTAssertEqual(verdict.verdict, .equivalent, "behavior itself matched — the gate is the declaration")
        XCTAssertEqual(verdict.diff.unobservedIntent, [#"Emits("NeverEmitted")"#])
        XCTAssertTrue(outcome.summary.contains("declared but not observed"), outcome.summary)
    }

    /// An intent that was pointed at but cannot load fails the run rather than silently running parity.
    func testAnUnreadableIntentFailsTheReplay() async {
        let planURL = scratch().appendingPathComponent("plan.json")
        _ = await cart(system: makeGood).runContinuous(.record(planURL: planURL))

        let outcome = await cart(system: makeGood).runContinuous(.replay(
            planURL: planURL,
            resultsDirectory: scratch(),
            intentURL: scratch().appendingPathComponent("absent.intent.json")
        ))

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.summary.hasPrefix("replay failed:"), outcome.summary)
    }

    func testAMissingPlanIsReportedRatherThanThrown() async {
        let outcome = await cart(system: makeGood).runContinuous(
            .replay(
                planURL: scratch().appendingPathComponent("absent.json"),
                resultsDirectory: scratch(),
                intentURL: nil
            )
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
