import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

private struct PromoCartSpec: SpecProviding {
    var spec: Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.perfile")
            .operations {
                Op("addCoffee") { $0.addItem(priceCents: 999, qty: 3) }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
    }
}

final class SpecProvidingTests: XCTestCase {
    private let subject = PromoCartSpec()
        .baselined(on: makeGood)
        .candidates {
            Candidate("RefactorCart", makeRefactor)
            Candidate("RoundBugCart", expecting: .diverged, makeRoundBug)
        }

    func testCandidateNamesAreTheMigrationArguments() {
        XCTAssertEqual(subject.candidateNames, ["RefactorCart", "RoundBugCart"])
    }

    func testCheckPassesWhenAPortEarnsItsDeclaredVerdict() async throws {
        // The counterexample meets its expectation by diverging, so neither throws.
        try await subject.check(candidate: "RefactorCart", reportsIn: scratch())
        try await subject.check(candidate: "RoundBugCart", reportsIn: scratch())
    }

    func testCheckNamesACandidateThatIsNoLongerDeclared() async {
        await XCTAssertThrowsErrorAsync {
            try await subject.check(candidate: "Renamed")
        } handler: { error in
            XCTAssertEqual(
                (error as? SpecCatalog.CheckFailure)?.description,
                "Renamed is no longer a declared candidate"
            )
        }
    }

    func testNoModeSelectsNothingSoAnOrdinaryTestRunIsUntouched() {
        XCTAssertEqual(subject.continuousModes(environment: [:]), [])
        XCTAssertEqual(
            subject.continuousModes(environment: ["HARUSPEC_MODE": "replay"]),
            [.replay]
        )
    }

    func testAConventionedPlanPathScopesTheModeToTheSpecItNames() {
        let name = subject.entry().name
        XCTAssertEqual(
            subject.continuousModes(environment: [
                "HARUSPEC_MODE": "record",
                "HARUSPEC_PLAN_PATH": "/plans/\(name).plan.json.gz"
            ]),
            [.record],
            "its own plan selects the suite"
        )
        XCTAssertEqual(
            subject.continuousModes(environment: [
                "HARUSPEC_MODE": "record",
                "HARUSPEC_PLAN_PATH": "/plans/some.other-spec.plan.json.gz"
            ]),
            [],
            "another spec's plan stands this suite down"
        )
        XCTAssertEqual(
            subject.continuousModes(environment: [
                "HARUSPEC_MODE": "replay",
                "HARUSPEC_PLAN_PATH": "/plans/plan.json"
            ]),
            [.replay],
            "a path outside the convention applies to every suite"
        )
    }

    func testContinuousRecordAndReplayRoundTripPerSpec() async throws {
        let planURL = scratch().appendingPathComponent("plan.json")
        let resultsDir = scratch()

        try await subject.checkContinuous(.record, environment: [
            "HARUSPEC_MODE": "record",
            "HARUSPEC_PLAN_PATH": planURL.path
        ])
        try await subject.checkContinuous(.replay, environment: [
            "HARUSPEC_MODE": "replay",
            "HARUSPEC_PLAN_PATH": planURL.path,
            "HARUSPEC_RESULTS_DIR": resultsDir.path
        ])
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("perfile-\(UUID().uuidString)", isDirectory: true)
    }

    func testContinuousReportsAMissingDestinationRatherThanThrowingRaw() async {
        await XCTAssertThrowsErrorAsync {
            try await subject.checkContinuous(.record, environment: ["HARUSPEC_MODE": "record"])
        } handler: { error in
            XCTAssertTrue(
                (error as? SpecCatalog.CheckFailure)?.description.contains("HARUSPEC_PLAN_PATH") ?? false,
                "\(error)"
            )
        }
    }
}

// The per-file shape: a spec declaration names no implementation, and the suite that binds it carries
// its own test surface, so a project with fifty specs keeps no central list to forget an entry in.
// These cover what a per-spec suite calls on the bound declaration — the candidate arguments, the
// one-call check, and the continuous selection that keeps an ordinary run untouched.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> PromoCart {
    RefactorCart(center: ctx.notifications)
}

private func makeRoundBug(_ ctx: SeamContext) -> PromoCart {
    RoundBugCart(center: ctx.notifications)
}
