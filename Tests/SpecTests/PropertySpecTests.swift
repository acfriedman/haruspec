import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// Observed properties, end to end: the spec names the boundary's properties (`.observes`), and the
// harness snapshots each at every capture boundary — the state contract, which gates always.

@Haruspec
protocol Drawer: AnyObject {
    var count: Int { get }
    var total: Int { get }
    func ring(amount: Int)
}

/// The baseline: writes `count` first, `total` second.
final class LegacyDrawer: Drawer {
    private(set) var count = 0
    private(set) var total = 0

    func ring(amount: Int) {
        count += 1
        total += amount
    }
}

/// The refactored port: same read surface, no stored counterparts at all.
final class ComputedDrawer: Drawer {
    private var amounts: [Int] = []
    var count: Int {
        amounts.count
    }

    var total: Int {
        amounts.reduce(0, +)
    }

    func ring(amount: Int) {
        amounts.append(amount)
    }
}

/// The state bug: the end total is wrong. No op returns a value here, so only the snapshot can say.
final class OverchargingDrawer: Drawer {
    private(set) var count = 0
    private(set) var total = 0

    func ring(amount: Int) {
        count += 1
        total += amount + 1
    }
}

/// The derived route: a `var` requirement on the boundary protocol becomes an observed property with
/// no authoring — name, label, and the snapshot read-back all mechanical.
@Haruspec
protocol Meter {
    var reading: Int { get }
    func bump(by amount: Int)
}

final class TickingMeter: Meter {
    private(set) var reading = 0

    func bump(by amount: Int) {
        reading += amount
    }
}

final class DerivedPropertyTests: XCTestCase {
    func testAVarRequirementDerivesAnObservedProperty() {
        XCTAssertEqual(DerivedMeter.derivedProperties.map(\.name), ["reading"])
        XCTAssertEqual(DerivedMeter.derivedProperties.map(\.label), ["Meter.reading"])
    }

    func testTheDerivedSpecObservesAndSnapshotsIt() async {
        let spec = Spec<any Meter>("meter").settled()

        XCTAssertEqual(spec.observedProperties.map(\.label), ["Meter.reading"])

        let trace = await spec.capture(
            make: { _ in TickingMeter() },
            order: spec.operations,
            cassette: Cassette()
        )
        XCTAssertTrue(trace.events.contains { $0.kind == .snapshot && $0.label == "Meter.reading" })
    }
}

final class PropertySpecTests: XCTestCase {
    private func drawerSpec() -> BaselinedSpec<any Drawer> {
        Spec<any Drawer>("till")
            .operations {
                Op("ring") { (till: any Drawer) in till.ring(amount: 7) }
            }
            .observes(
                Observed("Drawer.count") { $0.count },
                Observed("Drawer.total") { $0.total }
            )
            .baselined { _ in LegacyDrawer() }
    }

    /// A port with no stored counterparts: the snapshots alone carry the state contract to green.
    func testAComputedPortIsEquivalentOnSnapshotsAlone() async {
        let verdict = await drawerSpec().verify { _ in ComputedDrawer() }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    /// The snapshot is the gate: a wrong end state is red, and the divergence names the property.
    func testASnapshotCatchesAWrongEndState() async {
        let verdict = await drawerSpec().verify { _ in OverchargingDrawer() }

        XCTAssertEqual(verdict.verdict, .diverged)
        XCTAssertTrue(verdict.diff.divergences.contains {
            $0.kind == .valueMismatch && $0.label == "Drawer.total"
        })
    }

    /// The verdict names the observed properties whose snapshots gated, so a green is legible as
    /// exactly that.
    func testTheQualificationCarriesThePropertiesLine() async {
        let verdict = await drawerSpec().verify { _ in ComputedDrawer() }

        XCTAssertEqual(verdict.qualification.observedProperties, "Drawer.count, Drawer.total — snapshots gate")
    }
}
