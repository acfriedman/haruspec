import Foundation
import HaruspecAudit
import HaruspecCore
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// A subject handed context.scheduler and context.operationQueue reaches Combine and an operation queue
// in its source, but the capture holds that work: the audit names those channels as held, not as
// blind spots, and a green stays green.

final class HeldStandInAuditTests: XCTestCase {
    func testReachesThroughHeldStandInsAreNamedButDoNotGate() async {
        let spec = Spec<any Courier>("shipping.held").operations { Op("ship") { $0.ship("box") } }
        let verdict = await spec.baselined(on: shipper)
            .verify(candidate: shipper)
            .audited(against: packageRoot, declaring: .none)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
        XCTAssertEqual(verdict.qualification.heldStandIns, ["operationQueue", "scheduler"])
        XCTAssertEqual(verdict.qualification.blindSpots, ["Combine (held)", "dispatch (held)"])
    }

    func testAVerdictWithNoHeldStandInsStillGatesOnTheSameSource() async {
        let spec = Spec<any Courier>("shipping.held").operations { Op("ship") { $0.ship("box") } }
        let verdict = await spec.baselined(on: shipper).verify(candidate: shipper)
        let stripped = verdict.noting(origins: verdict.qualification.origins, heldStandIns: [])
            .audited(against: packageRoot, declaring: .none)

        XCTAssertEqual(stripped.verdict, .cannotVerify, stripped.report())
        XCTAssertEqual(stripped.qualification.blindSpots, ["Combine", "dispatch"])
    }

    private func shipper(_ context: SeamContext) -> any Courier {
        HeldCourier(
            scheduler: context.scheduler(.main),
            queue: context.operationQueue(.serial("shipping")),
            center: context.notifications
        )
    }

    /// The checkout the audit reads: this file is `<root>/Tests/SpecTests/HeldStandInAuditTests.swift`.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
