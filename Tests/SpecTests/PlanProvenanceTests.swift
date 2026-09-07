import Foundation
import HaruspecCore
import HaruspecSpec
import XCTest

// Record-on-merge's freshness model: provenance survives the artifact round-trip (and its absence
// decodes as absence, not an error), staleness is exactly coverage ∩ diff, and the sweep partitions
// a plans directory the way the reconciling workflow acts on it — fail-safe wherever freshness
// cannot be proven.

final class PlanProvenanceTests: XCTestCase {
    private func plan(
        _ spec: String,
        provenance: PlanProvenance? = nil
    ) -> SpecPlan {
        SpecPlan(
            specName: spec,
            seed: 42,
            variedSeams: [],
            probes: [],
            coveredClasses: ["Cart"],
            provenance: provenance
        )
    }

    private let cartProvenance = PlanProvenance(
        recordedAt: "sha0",
        coverageFiles: ["Features/Cart/CartManager.m", "Models/Product.m"]
    )

    // MARK: Staleness

    func testUnstampedPlanIsNeverFresh() {
        XCTAssertEqual(plan("cart").staleness(changedFiles: []), .unstamped)
    }

    func testUntouchedDependenciesAreFresh() {
        let plan = plan("cart", provenance: cartProvenance)
        XCTAssertEqual(plan.staleness(changedFiles: []), .fresh)
        XCTAssertEqual(plan.staleness(changedFiles: ["UI/CartViewController.swift"]), .fresh)
    }

    func testChangedCoveredFilesAreStaleAndNamed() {
        let plan = plan("cart", provenance: cartProvenance)
        XCTAssertEqual(
            plan.staleness(changedFiles: ["Models/Product.m", "UI/CartViewController.swift"]),
            .stale(overlap: ["Models/Product.m"])
        )
    }

    // MARK: Artifact round-trip

    func testProvenanceSurvivesTheGzipRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-\(UUID().uuidString).plan.json.gz")
        try plan("cart", provenance: cartProvenance).write(to: url)
        XCTAssertEqual(try SpecPlan(contentsOf: url).provenance, cartProvenance)
    }

    func testAPlanWithoutTheProvenanceKeyDecodesAsUnstamped() throws {
        // The committed pre-reconciler artifacts have no such key; absence is meaningful (stale),
        // so this is the one additive field that must not be a decode failure.
        var data = try plan("cart", provenance: cartProvenance).jsonData()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "provenance")
        data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try SpecPlan(jsonData: data).provenance)
    }

    // MARK: Sweep partition

    func testSweepPartitionsByStalenessWithReasons() {
        let sweep = PlanSweep.run(
            plans: [
                ("cart", plan("cart", provenance: cartProvenance)),
                ("search", plan(
                    "search",
                    provenance: PlanProvenance(recordedAt: "sha1", coverageFiles: ["Search/VM.swift"])
                ))
            ],
            census: nil,
            testSources: nil,
            changedFiles: { since in since == "sha0" ? ["Models/Product.m"] : [] }
        )
        XCTAssertEqual(sweep.stale, ["cart"])
        XCTAssertEqual(sweep.fresh, ["search"])
        XCTAssertEqual(sweep.recordedAt, ["cart": "sha0", "search": "sha1"])
        XCTAssertTrue(sweep.reasons["cart"]?.contains("Models/Product.m") == true)
        XCTAssertTrue(sweep.hasWork)
    }

    func testUnstampedAndUnanswerableRangesAreStaleFailSafe() {
        struct Unanswerable: Error {}
        let sweep = PlanSweep.run(
            plans: [
                ("cart", plan("cart")),
                ("search", plan(
                    "search",
                    provenance: PlanProvenance(recordedAt: "gone", coverageFiles: ["Search/VM.swift"])
                ))
            ],
            census: nil,
            testSources: nil,
            changedFiles: { _ in throw Unanswerable() }
        )
        XCTAssertEqual(sweep.stale, ["cart", "search"])
        XCTAssertTrue(sweep.reasons["cart"]?.contains("unstamped") == true)
        XCTAssertTrue(sweep.reasons["search"]?.contains("unanswerable") == true)
        // An unstamped plan means the catalog was never enumerated under this scheme either.
        XCTAssertTrue(sweep.censusAdvised)
    }

    func testCensusDecidesBirthsAndOrphans() {
        let sweep = PlanSweep.run(
            plans: [("cart", plan("cart", provenance: cartProvenance))],
            census: ["cart", "productstore"],
            testSources: nil,
            changedFiles: { _ in [] }
        )
        XCTAssertEqual(sweep.births, ["productstore"])
        XCTAssertEqual(sweep.orphaned, [])
        XCTAssertEqual(sweep.fresh, ["cart"])
        XCTAssertFalse(sweep.censusAdvised)
        XCTAssertTrue(sweep.hasWork)

        let orphaning = PlanSweep.run(
            plans: [("cart", plan("cart", provenance: cartProvenance))],
            census: [],
            testSources: nil,
            changedFiles: { _ in [] }
        )
        XCTAssertEqual(orphaning.orphaned, ["cart"])
    }

    func testADeletedSpecIsOrphanedOnlyNeverAlsoStale() {
        // Deleting a spec changes its covered file (stale) AND drops it from the census
        // (orphaned); orphaned must win — there is no suite left to replay or re-record.
        let sweep = PlanSweep.run(
            plans: [("cart", plan("cart", provenance: cartProvenance))],
            census: [],
            testSources: nil,
            changedFiles: { _ in ["Features/Cart/CartManager.m"] }
        )
        XCTAssertEqual(sweep.orphaned, ["cart"])
        XCTAssertEqual(sweep.stale, [])
    }

    func testUncoveredChangeUnderTheSpecTreeAdvisesACensus() {
        let stamped = plan("cart", provenance: cartProvenance)
        let changed = ["LegacyAppTests/NewSpec.swift"]
        let advised = PlanSweep.run(
            plans: [("cart", stamped)],
            census: nil,
            testSources: "LegacyAppTests/",
            changedFiles: { _ in changed }
        )
        XCTAssertTrue(advised.censusAdvised)
        XCTAssertTrue(advised.hasWork)

        // The same change with no test-sources prefix, or outside it, decides nothing.
        let elsewhere = PlanSweep.run(
            plans: [("cart", stamped)],
            census: nil,
            testSources: "LegacyAppTests/",
            changedFiles: { _ in ["UI/CartViewController.swift"] }
        )
        XCTAssertFalse(elsewhere.censusAdvised)
        XCTAssertFalse(elsewhere.hasWork)
    }

    func testACoveredTestSourceChangeAdvisesNoCensus() {
        // A spec's own file is in its coverage (the recording executes it): editing it re-records
        // that spec without implying the catalog changed.
        let sweep = PlanSweep.run(
            plans: [("cart", plan(
                "cart",
                provenance: PlanProvenance(
                    recordedAt: "sha0",
                    coverageFiles: ["LegacyAppTests/CartMigrationSpec.swift"]
                )
            ))],
            census: nil,
            testSources: "LegacyAppTests/",
            changedFiles: { _ in ["LegacyAppTests/CartMigrationSpec.swift"] }
        )
        XCTAssertEqual(sweep.stale, ["cart"])
        XCTAssertFalse(sweep.censusAdvised)
    }

    func testEmptyPlansDirectoryAdvisesACensus() {
        let sweep = PlanSweep.run(plans: [], census: nil, testSources: nil, changedFiles: { _ in [] })
        XCTAssertTrue(sweep.censusAdvised)
        XCTAssertTrue(sweep.hasWork)
    }
}
