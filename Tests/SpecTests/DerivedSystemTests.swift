import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// The baseline's construction, derived. The pasted protocol carries the baseline's init requirement, so
// the forwarder can mirror it and wire it: collaborators resolve to their synthesized doubles by
// conformance (the stamped collaborator protocol *refines* the boundary — conformance is the
// registry), the NotificationCenter parameter takes the capture's isolated center. With ops and
// system both derived, the whole spec is one entry point and its authored residue.

/// The collaborator boundary. The double's pasted protocol refines it, which is what `resolve` matches.
protocol ReceiptPrinting {
    func printLine(total: Int)
}

@Haruspec
protocol Printer: ReceiptPrinting {
    func printLine(total: Int)
}

/// The baseline: a plain Swift class with constructor-injected collaborators and — deliberately —
/// no `init()`. A pasted init suppresses the forwarder's `= KioskManager()` default, so nothing
/// requires the NSObject-style no-arg init a Swift baseline often lacks.
final class KioskManager {
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

/// The pasted interface, init included — construction is part of the Clang interface, and pasting it
/// is what lets the wiring derive. Every conformer (baseline and ports) carries the same init, which
/// is what lets the spec build any of them from its type.
@Haruspec
protocol Kiosk: AnyObject {
    init(printer: ReceiptPrinting, center: NotificationCenter)
    func ring(amount: Int)
    func total() -> Int
}

extension KioskManager: Kiosk {}

/// A faithful port, conforming directly (final class, init in the body satisfies the requirement)
/// and carrying no Haruspec attribute — the forwarder is its capture boundary too.
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

/// A capture resource: infrastructure the subject runs on — the engine-side stand-in for an
/// isolated in-memory store. Not a boundary; state in it is observed through `tally()`.
final class TallyBook {
    var rows: [Int] = []
}

/// A baseline whose behavior *is* its interaction with injected state — the persistence-bearing
/// subject shape, scaled down.
final class RegisterManager {
    private let book: TallyBook
    private let center: NotificationCenter

    init(book: TallyBook, center: NotificationCenter) {
        self.book = book
        self.center = center
    }

    func punch(amount: Int) {
        book.rows.append(max(0, amount))
    }

    func tally() -> Int {
        let total = book.rows.reduce(0, +)
        center.post(name: .init("RegisterDidTally"), object: nil, userInfo: ["total": total])
        return total
    }
}

@Haruspec
protocol Register: AnyObject {
    init(book: TallyBook, center: NotificationCenter)
    func punch(amount: Int)
    func tally() -> Int
}

extension RegisterManager: Register {}

final class SwiftRegister: Register {
    private let book: TallyBook
    private let center: NotificationCenter

    init(book: TallyBook, center: NotificationCenter) {
        self.book = book
        self.center = center
    }

    func punch(amount: Int) {
        book.rows.append(max(0, amount))
    }

    func tally() -> Int {
        let total = book.rows.reduce(0, +)
        center.post(name: .init("RegisterDidTally"), object: nil, userInfo: ["total": total])
        return total
    }
}

final class DerivedSystemTests: XCTestCase {
    func testTheCatalogCarriesTheDerivedSystemFactory() {
        XCTAssertNotNil(DerivedKiosk.derivedSystem, "a pasted init derives the wiring")
    }

    /// The port is built and wrapped exactly as the baseline was — nothing authored, no attribute
    /// on the port. This is the check a migration test writes.
    func testAConformerChecksFromItsTypeAlone() async throws {
        let verdict = try await spec.vary {
            Ordering(max: 4)
            Budget(runs: 60)
        }.baselined(on: KioskManager.self).check(SwiftKiosk.self)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testADerivedSpecExploresAtTheDefaultsWithoutAVaryBlock() {
        let settled = spec.settled()

        XCTAssertTrue(settled.exploreOrdering, "ordering variation is half the point of deriving")
        XCTAssertEqual(settled.maxOrderings, SpecDefaults.derivedOrderingMax)
        XCTAssertEqual(settled.explorationBudget, SpecDefaults.derivedBudget)
    }

    func testAnExplicitVaryOverridesTheDerivedDefaults() {
        // The derivation settles at binding, after every `.vary` the spec declares.
        let tuned = spec.vary {
            Ordering(max: 4)
            Budget(runs: 40)
        }
        .settled()

        XCTAssertEqual(tuned.maxOrderings, 4)
        XCTAssertEqual(tuned.explorationBudget, 40)
    }

    func testAClosureBuiltPortIsWrappedByTheSameBoundary() async {
        // The authored route survives for a port with bespoke wiring; the runner still wraps what
        // the closure returns, so an unattributed port records through the forwarder.
        let verdict = await spec.vary {
            Ordering(max: 4)
            Budget(runs: 60)
        }.baselined(on: KioskManager.self).verify { context in
            SwiftKiosk(
                printer: context.double(DoublePrinter.self),
                center: context.notifications
            )
        }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testAPureSwiftContinuousRoundTripRunsOnTheDerivedSystem() async throws {
        // The continuous shape, Swift to Swift: record the plan from the derived system, replay it
        // against the same build — no Obj-C anywhere, no construction closure, no `.vary`. This is the spec a
        // Swift-only subject ships to CI.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiosk-derived-\(UUID().uuidString).haruspec-plan")
        defer { try? FileManager.default.removeItem(at: url) }
        let bounded = spec.vary {
            Ordering(max: 4)
            Budget(runs: 60)
        }.baselined(on: KioskManager.self)

        _ = try await bounded.record(to: url)
        let verdict = try await bounded.verify(replayingContentsOf: url)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
        XCTAssertTrue(verdict.stability.isStable, "the derived system must replay deterministically")
    }

    /// The collapsed spec: one entry point, no construction closure, no `.vary` — the authored residue alone.
    private var spec: Spec<Kiosk> {
        Spec<Kiosk>("kiosk.derived") {
            Amend("total").last()
        }
    }

    func testACaptureResourceResolvesAConstructorParameterNoDoubleServes() async {
        // The persistence-bearing-subject shape: the injected state is a resource (.provides), built
        // fresh per capture for isolation, and observed through the subject's own read op — which is
        // what makes hidden state comparable surface.
        let spec = Spec<Register>("register.derived")
            .provides(TallyBook.self) { _ in TallyBook() }
            .vary {
                Ordering(max: 4)
                Budget(runs: 60)
            }
            .baselined(on: RegisterManager.self)

        let verdict = await spec.verify { context in
            SwiftRegister(book: context.resolve(TallyBook.self), center: context.notifications)
        }

        XCTAssertEqual(
            verdict.verdict,
            .equivalent,
            "fresh-per-capture resources must keep probes independent\n\(verdict.report())"
        )
    }

    func testResolveConstructsAndRegistersTheConformanceMatchedDouble() {
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())

        let resolved = context.resolve(ReceiptPrinting.self)

        XCTAssertTrue(resolved is DoublePrinter, "the pasted protocol's refinement is the registry")
    }
}
