import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// A build named by its initializer. The port below takes a dependency the baseline lacks, so the
// pasted init cannot build it; its initializer still resolves every parameter.

/// A faithful port that keeps its running total in an injected resource the baseline never had.
final class SwiftKioskOnTally: Kiosk {
    private let printer: ReceiptPrinting
    private let center: NotificationCenter
    private let book: TallyBook

    init(printer: ReceiptPrinting, center: NotificationCenter, book: TallyBook) {
        self.printer = printer
        self.center = center
        self.book = book
    }

    convenience init(printer: ReceiptPrinting, center: NotificationCenter) {
        self.init(printer: printer, center: center, book: TallyBook())
    }

    func ring(amount: Int) {
        book.rows.append(max(0, amount))
        printer.printLine(total: total())
        center.post(name: .init("KioskDidVend"), object: nil, userInfo: ["cents": total()])
    }

    func total() -> Int {
        book.rows.reduce(0, +)
    }
}

final class InitializerBuildTests: XCTestCase {
    /// No derivation: the baseline is declared by its initializer, as a hand-wired spec would.
    private var spec: Spec<Kiosk> {
        Spec<Kiosk>("kiosk.initializers")
            .system(KioskManager.init(printer:center:))
            .operations {
                Op("ring", varying: .int(0 ... 50).named("amount")) { kiosk, amount in kiosk.ring(amount: Int(amount)) }
                Op("total") { kiosk in _ = kiosk.total() }.last()
            }
            .vary {
                Ordering(max: 4)
                Budget(runs: 40)
            }
    }

    func testAPortWithItsOwnDependenciesChecksFromItsInitializer() async throws {
        let verdict = try await spec.provides(TallyBook.init).check(SwiftKioskOnTally.init(printer:center:book:))

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testAnOptionalParameterTakesWhatItsWrappedTypeResolvesTo() async throws {
        // An initializer imported from unannotated Obj-C takes optionals.
        let unannotated = { (printer: ReceiptPrinting?, center: NotificationCenter?, book: TallyBook!) in
            SwiftKioskOnTally(printer: printer!, center: center!, book: book)
        }
        let verdict = try await spec.provides(TallyBook.init).check(unannotated)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testAResourceProvidedOptionalServesItsWrappedType() async throws {
        // An unannotated Obj-C initializer imports as `init!`, returning an optional.
        let verdict = try await spec
            .provides { () -> TallyBook? in TallyBook() }
            .check(SwiftKioskOnTally.init(printer:center:book:))

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testAContextBuildsFromAnInitializer() async {
        let candidate = await spec.provides(TallyBook.init).verify("SwiftKioskOnTally") { context in
            context.build(SwiftKioskOnTally.init(printer:center:book:))
        }

        XCTAssertEqual(candidate.verdict.verdict, .equivalent)
    }
}
