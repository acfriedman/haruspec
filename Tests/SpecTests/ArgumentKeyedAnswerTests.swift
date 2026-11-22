import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// A stamped double answers per argument tuple. A port that asks the same questions in another order
// gets the same answers, so only the order of the calls can differ — never the values behind them.

protocol StockLooking {
    func stock(sku: String) -> Int
}

@Haruspec
protocol Shelf: StockLooking {
    func stock(sku: String) -> Int
}

@Haruspec
protocol Restock: AnyObject {
    func report()
}

/// Reads two SKUs' stock, first then second, and announces both.
final class LegacyRestock: Restock {
    private let shelf: StockLooking
    private let center: NotificationCenter

    init(shelf: StockLooking, center: NotificationCenter) {
        self.shelf = shelf
        self.center = center
    }

    func report() {
        let first = shelf.stock(sku: "A")
        let second = shelf.stock(sku: "B")
        center.post(name: .init("RestockDidReport"), object: self, userInfo: ["A": first, "B": second])
    }
}

/// The same report, reading the second SKU first.
final class ReorderedRestock: Restock {
    private let shelf: StockLooking
    private let center: NotificationCenter

    init(shelf: StockLooking, center: NotificationCenter) {
        self.shelf = shelf
        self.center = center
    }

    func report() {
        let second = shelf.stock(sku: "B")
        let first = shelf.stock(sku: "A")
        center.post(name: .init("RestockDidReport"), object: self, userInfo: ["A": first, "B": second])
    }
}

final class ArgumentKeyedAnswerTests: XCTestCase {
    func testAPortAskingInAnotherOrderGetsTheSameAnswers() async {
        let verdict = await spec.verify { $0.build(ReorderedRestock.init(shelf:center:)) }

        // The calls moved, and that is all that differs: no value, here or downstream.
        let kinds = Set(verdict.result.diff.divergences.map(\.kind))
        XCTAssertEqual(kinds, [.reordered], verdict.report())
    }

    private var spec: BaselinedSpec<Restock> {
        Spec<Restock>("restock.argument-keyed")
            .operations { Op("report") { $0.report() } }
            .vary {
                Seam("Shelf.stock", .int(0 ... 9))
                Budget(runs: 30)
            }
            .baselined(on: LegacyRestock.init(shelf:center:))
    }

    func testAReplayedSnapshotAnswersByArguments() {
        let baseline = Cassette(replaying: CassetteData(tracks: ["Shelf.stock": [.int(3), .int(7)]]))
        XCTAssertEqual(baseline.int(seam: "Shelf.stock", qualifier: "sku=A", live: { 0 }), 3)
        XCTAssertEqual(baseline.int(seam: "Shelf.stock", qualifier: "sku=B", live: { 0 }), 7)

        let candidate = Cassette(replaying: baseline.snapshot())
        XCTAssertEqual(candidate.int(seam: "Shelf.stock", qualifier: "sku=B", live: { 0 }), 7)
        XCTAssertEqual(candidate.int(seam: "Shelf.stock", qualifier: "sku=A", live: { 0 }), 3)
        XCTAssertTrue(candidate.misses.isEmpty)
    }

    func testATupleTheBaselineNeverAskedDrawsAfterTheBoundValues() {
        let baseline = Cassette(replaying: CassetteData(tracks: ["Shelf.stock": [.int(3), .int(7)]]))
        _ = baseline.int(seam: "Shelf.stock", qualifier: "sku=A", live: { 0 })

        let candidate = Cassette(replaying: baseline.snapshot())
        XCTAssertEqual(candidate.int(seam: "Shelf.stock", qualifier: "sku=C", live: { 0 }), 7)
    }
}
