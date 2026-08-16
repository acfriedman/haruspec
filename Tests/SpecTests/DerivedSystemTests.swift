import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// The `.system` closure, derived. The pasted protocol carries the baseline's init requirement, so
// the forwarder can mirror it and wire it: collaborators resolve to their synthesized doubles by
// conformance (the pasted @TracedDouble protocol *refines* the boundary — conformance is the
// registry), the NotificationCenter parameter takes the capture's isolated center. With ops and
// system both derived, the whole spec is one entry point and its authored residue.

/// The collaborator boundary. The double's pasted protocol refines it, which is what `resolve` matches.
protocol ReceiptPrinting {
    func printLine(total: Int)
}

@TracedDouble(label: "Printer")
protocol PrinterDouble: ReceiptPrinting {
    func printLine(total: Int)
}

/// The production collaborator behind the plain init — what the harness swaps out, never sees.
private struct ConsolePrinter: ReceiptPrinting {
    func printLine(total _: Int) {}
}

/// The "legacy" baseline: constructor-injected collaborators, exactly the CartManager shape —
/// including the plain init that defaults them to production instances (the forwarder's generated
/// `init(_ wrapped: KioskManager = KioskManager())` relies on it, as `+sharedManager` shapes do).
final class KioskManager {
    private let printer: ReceiptPrinting
    private let center: NotificationCenter
    private var cents = 0

    convenience init() {
        self.init(printer: ConsolePrinter(), center: .default)
    }

    init(printer: ReceiptPrinting, center: NotificationCenter) {
        self.printer = printer
        self.center = center
    }

    func ring(amount: Int) {
        cents += max(0, amount)
        printer.printLine(total: cents)
        center.post(name: .init("KioskDidVend"), object: nil, userInfo: ["cents": cents])
    }

    func total() -> Int {
        cents
    }
}

/// The pasted interface, init included — construction is part of the Clang interface, and pasting it
/// is what lets the wiring derive. Conformers (the forwarder, ports) must carry the same init.
@DerivedOps
@TracedForwarder(wrapping: KioskManager.self, label: "Kiosk")
protocol Kiosk: AnyObject {
    init(printer: ReceiptPrinting, center: NotificationCenter)
    func ring(amount: Int)
    func total() -> Int
}

/// A faithful port, conforming directly (final class, init in the body satisfies the requirement).
@Traced("Kiosk")
final class SwiftKiosk: Kiosk {
    private let printer: ReceiptPrinting
    private let center: NotificationCenter
    private var cents = 0

    init(printer: ReceiptPrinting, center: NotificationCenter) {
        self.printer = printer
        self.center = center
    }

    func ring(amount: Int) {
        cents += max(0, amount)
        printer.printLine(total: cents)
        center.post(name: .init("KioskDidVend"), object: nil, userInfo: ["cents": cents])
    }

    func total() -> Int {
        cents
    }
}

final class DerivedSystemTests: XCTestCase {
    /// The collapsed spec: one entry point, no `.system`, no `.vary` — the authored residue alone.
    private var spec: Spec<Kiosk> {
        Spec<Kiosk>("kiosk.derived", derivedFrom: DerivedKiosk.self) {
            Amend("total").last()
        }
    }

    func testTheCatalogCarriesTheDerivedSystemFactory() {
        XCTAssertNotNil(DerivedKiosk.derivedSystem, "a pasted init + forwarder sibling derive the wiring")
    }

    func testADerivedSpecExploresAtTheDefaultsWithoutAVaryBlock() {
        XCTAssertTrue(spec.exploreOrdering, "ordering variation is half the point of deriving")
        XCTAssertEqual(spec.maxOrderings, SpecDefaults.derivedOrderingMax)
        XCTAssertEqual(spec.explorationBudget, SpecDefaults.derivedBudget)
    }

    func testAnExplicitVaryOverridesTheDerivedDefaults() {
        let tuned = spec.vary {
            Ordering(max: 4)
            Budget(runs: 40)
        }

        XCTAssertEqual(tuned.maxOrderings, 4)
        XCTAssertEqual(tuned.explorationBudget, 40)
    }

    func testTheDerivedSystemDrivesAFullDifferentialAgainstAPort() async {
        // Baseline construction is entirely derived: TracedTill(resolving:) resolves the printer
        // double by conformance and takes the capture's center. The candidate authors its closure —
        // the port side is the next collapse, not this one.
        let verdict = await spec.vary {
            Ordering(max: 4)
            Budget(runs: 60)
        }.verify(against: { context in
            SwiftKiosk(
                printer: context.double(TracedPrinterDouble.self),
                center: context.notifications
            )
        })

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testResolveConstructsAndRegistersTheConformanceMatchedDouble() {
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())

        let resolved = context.resolve(ReceiptPrinting.self)

        XCTAssertTrue(resolved is TracedPrinterDouble, "the pasted protocol's refinement is the registry")
    }
}
