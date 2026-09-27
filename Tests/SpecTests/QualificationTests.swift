import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// The disclaimer, rendered per verdict. These pin the three feeds that used to die before reaching
// the artifact (probe count, per-seam positions, boundary-schedule truncation), the placeholder that
// keeps the block honest until the audit card lands ("not audited", never an empty clean list), and
// the stamp that turns a pre-block artifact into "re-run" instead of a keyNotFound.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}

private func makeRefactor(_ ctx: SeamContext) -> PromoCart {
    RefactorCart(center: ctx.notifications)
}

final class QualificationTests: XCTestCase {
    /// The serialization tests' cart, with the promo op renameable so a replay can be driven into
    /// the abstain tier (a plan op this build no longer declares).
    private func cart(
        system: @escaping (SeamContext) -> PromoCart,
        promoLabel: String = "promo"
    ) -> Spec<PromoCart> {
        Spec<PromoCart>("promo-cart.qualification")
            .system(system)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op(promoLabel) { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 10)
            }
    }

    // MARK: - Assembly

    func testALiveVerdictCarriesTheSurfaceItWasMeasuredOver() async {
        let verdict = await cart(system: makeGood).verify(against: makeRefactor)

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertTrue(verdict.qualification.coveredClasses.contains("PromoCart"))
        XCTAssertEqual(verdict.qualification.operations, 3)
        XCTAssertEqual(verdict.qualification.probes, verdict.exploration.runs)
        // Ordering(max: 10) explores repeated ops, so the golden template reads coffeeQty at two
        // positions — exactly the number a reader needs to judge "was multiplicity ever varied".
        XCTAssertEqual(verdict.qualification.seamPositions, ["coffeeQty": 2])
        XCTAssertNil(verdict.qualification.blindSpots, "nothing may claim an audit that never ran")
        XCTAssertGreaterThan(verdict.exploration.boundaryEdgesScheduled, 0)
        XCTAssertEqual(
            verdict.exploration.boundaryEdgesCovered,
            verdict.exploration.boundaryEdgesScheduled,
            "the default 64-variant budget covers this spec's whole edge schedule"
        )
    }

    func testAReplayVerdictQualifiesOffThePlanNotARederivation() async {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeGood).verify(replaying: plan)

        XCTAssertEqual(verdict.qualification.probes, plan.probes.count)
        XCTAssertEqual(verdict.qualification.coveredClasses, plan.coveredClasses)
        XCTAssertEqual(verdict.qualification.seamPositions, ["coffeeQty": 2])
        XCTAssertGreaterThan(
            verdict.exploration.boundaryEdgesScheduled,
            0,
            "the schedule is recomputable from the plan's golden probe — no plan field needed"
        )
    }

    // MARK: - Origins (which sources the covered labels came from)

    /// The label is not a type name — `PromoCart` is answered here by two different classes — so the
    /// verdict carries the declarations themselves rather than leaving an audit to search for the name.
    func testALiveVerdictNamesWhereItsCoveredLabelsAreDeclared() async {
        let verdict = await cart(system: makeGood).verify(against: makeRefactor)

        let origins = verdict.qualification.origins
        XCTAssertEqual(Set(origins.map(\.label)), ["PromoCart"])
        XCTAssertEqual(
            Set(origins.compactMap(\.symbol)),
            ["GoodCart", "RefactorCart"],
            "baseline and candidate both — a PR audit needs the sources the candidate introduced"
        )
        XCTAssertTrue(
            origins.allSatisfy { $0.source == nil },
            "a forwarder names the wrapped type and no file — the audit resolves the declaration"
        )
    }

    /// On replay the golden comes from the plan, so only the current build declares anything — which
    /// is the side a PR is judged on anyway. The line must describe that build, not the recording.
    func testAReplayVerdictNamesTheSourcesThisBuildRan() async {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeGood).verify(replaying: plan)

        XCTAssertEqual(Set(verdict.qualification.origins.compactMap(\.symbol)), ["GoodCart"])
    }

    func testTheQualificationBlockRendersTheDeclaringSources() async {
        let markdown = await cart(system: makeGood).verify(against: makeRefactor).markdownReport()

        XCTAssertTrue(markdown.contains("PromoCart ← GoodCart ("), markdown)
        XCTAssertTrue(markdown.contains("RefactorCart ("), markdown)
    }

    // MARK: - Boundary-schedule truncation (the exploration card's "says nothing about the 11 it dropped")

    func testATruncatedBoundaryScheduleReportsItsDroppedEdges() async {
        // Two varied seams → 8 scheduled edges; a budget of 5 variants covers 5 and must say so.
        let spec = Spec<PromoCart>("promo-cart.truncated")
            .system(makeGood)
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("addMug") { cart, seams in
                    cart.addItem(priceCents: 499, qty: Int(seams.int("mugQty", default: 5)))
                }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Seam("mugQty", .int(0 ... 9))
                Budget(runs: 5)
            }
        let verdict = await spec.verify(against: makeRefactor)

        // Five variants: three edge pins and two combined, interleaved — the budget is shared, so a
        // truncated schedule drops edges *and* says how much of it paired the seams instead.
        XCTAssertEqual(verdict.exploration.boundaryEdgesScheduled, 8)
        XCTAssertEqual(verdict.exploration.boundaryEdgesCovered, 3)
        XCTAssertEqual(verdict.exploration.combinedVariantsCovered, 2)
        XCTAssertTrue(
            verdict.markdownReport()
                .contains("boundary edges 3 of 8 scheduled (5 dropped — budget) · 2 combined (every seam at once)"),
            verdict.markdownReport()
        )
    }

    // MARK: - Rendering (every verdict, placeholders that never overstate)

    func testAGreenVerdictStatesItsBlindSpotLine() async {
        let markdown = await cart(system: makeGood).verify(against: makeRefactor).markdownReport()

        XCTAssertTrue(markdown.contains("What this verdict rests on:"), markdown)
        XCTAssertTrue(markdown.contains("not audited"), markdown)
        XCTAssertTrue(markdown.contains("single replay — reproduction not measured"), markdown)
        XCTAssertTrue(markdown.contains("coffeeQty (2 positions)"), markdown)
    }

    func testAnAbstentionKeepsItsWordingAndGainsTheInventory() async {
        let plan = await cart(system: makeGood).record()
        let verdict = await cart(system: makeGood, promoLabel: "promoRenamed").verify(replaying: plan)
        let markdown = verdict.markdownReport()

        XCTAssertEqual(verdict.verdict, .cannotVerify)
        XCTAssertTrue(markdown.contains("this check does not pass"), markdown)
        XCTAssertTrue(markdown.contains("What this verdict rests on:"), markdown)
        XCTAssertTrue(markdown.contains("not audited"), markdown)
    }

    func testAMeasuredReplayRendersItsStabilityLineInTheBlock() async {
        let plan = await cart(system: makeGood).record()
        let markdown = await cart(system: makeGood).verify(replaying: plan).markdownReport()

        XCTAssertTrue(markdown.contains("3/3 identical replays"), markdown)
    }

    func testTheHTMLReportRendersTheSameBlock() async {
        let html = await cart(system: makeGood).verify(against: makeRefactor).htmlReport()

        XCTAssertTrue(html.contains("What this verdict rests on"), "the artifact and comment share the block")
        XCTAssertTrue(html.contains("not audited"))
    }

    // MARK: - The stamp

    func testAnUnstampedResultArtifactIsRefusedWithReRunNotKeyNotFound() async throws {
        let verdict = await cart(system: makeGood).verify(against: makeRefactor)
        var json = try JSONSerialization.jsonObject(with: verdict.jsonData()) as? [String: Any] ?? [:]
        json.removeValue(forKey: "schemaVersion")

        XCTAssertThrowsError(
            try SpecVerdict(jsonData: JSONSerialization.data(withJSONObject: json))
        ) { error in
            XCTAssertEqual(
                error as? SpecVerdictError,
                .unsupportedSchemaVersion(found: nil, supported: SpecVerdict.supportedSchemaVersion)
            )
        }
    }

    func testAFutureSchemaIsRefusedByNumber() async throws {
        let verdict = await cart(system: makeGood).verify(against: makeRefactor)
        var json = try JSONSerialization.jsonObject(with: verdict.jsonData()) as? [String: Any] ?? [:]
        json["schemaVersion"] = 999

        XCTAssertThrowsError(
            try SpecVerdict(jsonData: JSONSerialization.data(withJSONObject: json))
        ) { error in
            XCTAssertEqual(
                error as? SpecVerdictError,
                .unsupportedSchemaVersion(found: 999, supported: SpecVerdict.supportedSchemaVersion)
            )
        }
    }
}
