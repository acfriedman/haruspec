import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// Observed properties, end to end: the spec names the boundary's properties (`.observes`), the
// harness snapshots each at every capture boundary (the state contract — gates always), and the
// write timeline recorded by `@Traced`'s property instrumentation joins the diff under
// `Tolerance.mutationOrder`. The separating case is a port that computes the same end state through
// a different write order: identical to every caller, different to anything observing the
// properties between writes.

protocol Drawer: AnyObject {
    var count: Int { get }
    var total: Int { get }
    func ring(amount: Int)
}

/// The baseline: writes `count` first, `total` second.
@Traced("Drawer")
final class LegacyDrawer: Drawer {
    private(set) var count = 0
    private(set) var total = 0

    func ring(amount: Int) {
        count += 1
        total += amount
    }
}

/// The faithful-values port with a reordered write vector: an observer between the writes sees
/// `total` updated against a stale `count`.
@Traced("Drawer")
final class ReorderedDrawer: Drawer {
    private(set) var count = 0
    private(set) var total = 0

    func ring(amount: Int) {
        total += amount
        count += 1
    }
}

/// The refactored port: same read surface, no stored counterparts at all — its write timeline for
/// the observed properties is empty by construction, not by bug.
@Traced("Drawer")
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
@Traced("Drawer")
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
@DerivedOps
protocol Meter {
    var reading: Int { get }
    func bump(by amount: Int)
}

@Traced("Meter")
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
        let spec = Spec<any Meter>("meter", derivedFrom: DerivedMeter.self)
            .system { _ in TickingMeter() }

        XCTAssertEqual(spec.observedProperties.map(\.label), ["Meter.reading"])

        let trace = await spec.capture(
            make: spec.makeSystem,
            order: spec.operations,
            cassette: Cassette()
        )
        XCTAssertEqual(trace.mutationCapture, .full)
        XCTAssertTrue(trace.events.contains { $0.kind == .snapshot && $0.label == "Meter.reading" })
    }
}

final class PropertySpecTests: XCTestCase {
    private func drawerSpec() -> Spec<any Drawer> {
        Spec<any Drawer>("till")
            .system { _ in LegacyDrawer() }
            .operations {
                Op("ring") { (till: any Drawer) in till.ring(amount: 7) }
            }
            .observes(
                Observed("Drawer.count") { $0.count },
                Observed("Drawer.total") { $0.total }
            )
    }

    /// The default: the reorder is reported (the writes are on the trace) but does not gate — order
    /// is contract only where something observes it, which nothing here declared.
    func testAReorderedWriteVectorIsAdvisoryByDefault() async {
        let verdict = await drawerSpec().verify(against: { _ in ReorderedDrawer() })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertTrue(verdict.diff.divergences.contains { $0.kind == .reordered && $0.isAdvisory })
    }

    /// Opted up to `.gating`, the same port is red — and one `Reorders` line per moved write is the
    /// declared exit, exactly the safe-by-default shape every other structural gate uses.
    func testGatingCatchesTheReorderAndReordersDeclaresIt() async {
        let spec = drawerSpec().tolerate(Tolerance(mutationOrder: .gating))

        let undeclared = await spec.verify(against: { _ in ReorderedDrawer() })
        XCTAssertEqual(undeclared.verdict, .diverged)

        let declared = await spec.verify(
            against: { _ in ReorderedDrawer() },
            declaring: Intent { Reorders("Drawer.count", "Drawer.total") }
        )
        XCTAssertEqual(declared.verdict, .equivalent)
    }

    /// A port with no stored counterparts writes nothing — under the advisory default its empty
    /// timeline is reported, and the snapshots alone carry the state contract to green.
    func testAComputedPortIsEquivalentOnSnapshotsAlone() async {
        let verdict = await drawerSpec().verify(against: { _ in ComputedDrawer() })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertTrue(verdict.diff.divergences.contains { $0.kind == .missingEvent && $0.isAdvisory })
    }

    /// The snapshot is the gate: a wrong end state is red even with the write timeline ignored, and
    /// the divergence names the property.
    func testASnapshotCatchesAWrongEndStateEvenWithOrderIgnored() async {
        let spec = drawerSpec().tolerate(Tolerance(mutationOrder: .ignored))
        let verdict = await spec.verify(against: { _ in OverchargingDrawer() })

        XCTAssertEqual(verdict.verdict, .diverged)
        XCTAssertTrue(verdict.diff.divergences.contains {
            $0.kind == .valueMismatch && $0.label == "Drawer.total"
        })
    }

    /// A port's *private* state never manufactures divergences: `ComputedDrawer` writes its internal
    /// `amounts` array on every op, and under `.gating` those writes still don't gate — only the
    /// observed labels are surface. (Its missing observed writes do gate, and are declarable.)
    func testPrivateStateStaysOutOfTheDiff() async {
        let spec = drawerSpec().tolerate(Tolerance(mutationOrder: .gating))
        let verdict = await spec.verify(
            against: { _ in ComputedDrawer() },
            declaring: Intent {
                Omits("Drawer.count")
                Omits("Drawer.total")
            }
        )

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertFalse(verdict.diff.divergences.contains { $0.label == "Drawer.amounts" })
    }

    /// The verdict says what it did about properties — observed labels, snapshots gating, and the
    /// write-order policy — so a green over an advisory timeline is legible as exactly that.
    func testTheQualificationCarriesThePropertiesLine() async {
        let verdict = await drawerSpec().verify(against: { _ in ReorderedDrawer() })

        let line = try? XCTUnwrap(verdict.qualification.propertyMutations)
        XCTAssertTrue(line?.contains("Drawer.count") == true)
        XCTAssertTrue(line?.contains("write order advisory") == true)
    }
}
