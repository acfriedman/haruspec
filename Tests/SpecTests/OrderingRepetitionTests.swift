import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// Applying an operation twice is where a lot of legacy behavior hides — merge-into-existing rather
// than append, remove-what-is-not-there — so exploration places a repeatable op more than once
// rather than making the author hand-write a second `addCoffeeAgain` op to reach it.

private final class Ledger {
    private(set) var calls: [String] = []
    func push(_ name: String) {
        calls.append(name)
    }
}

final class OrderingRepetitionTests: XCTestCase {
    private func spec(repeating: Int = 2, onceOnPush: Bool = false) -> Spec<Ledger> {
        var push = Op<Ledger>("push") { $0.push("push") }
        if onceOnPush {
            push = push.once()
        }
        return Spec<Ledger>("ledger.repetition")
            .system { _ in Ledger() }
            .operations {
                push
                Op("pull") { $0.push("pull") }
                Op("close") { $0.push("close") }.last()
            }
            .vary { Ordering(max: 200, repeating: repeating) }
    }

    private func orderings(_ spec: Spec<Ledger>) -> [[String]] {
        spec.record().probes.map(\.ordering)
    }

    func testARepeatableOpIsPlacedTwiceByDefault() {
        let counts = orderings(spec()).map { order in order.filter { $0 == "push" }.count }

        XCTAssertTrue(counts.contains(2), "default exploration should apply an op more than once")
        XCTAssertEqual(counts.max(), 2, "and not more times than declared")
    }

    func testRepeatingOneRestoresPermutations() {
        for order in orderings(spec(repeating: 1)) {
            XCTAssertEqual(order.filter { $0 == "push" }.count, 1)
            XCTAssertEqual(Set(order).count, order.count, "no label should appear twice")
        }
    }

    func testAnOpMarkedOnceIsNeverRepeated() {
        let explored = orderings(spec(onceOnPush: true))

        XCTAssertTrue(explored.allSatisfy { $0.filter { $0 == "push" }.count == 1 })
        XCTAssertTrue(explored.contains { $0.filter { $0 == "pull" }.count == 2 }, "others still repeat")
    }

    func testALastOpIsPinnedToOneOccurrenceAndStaysLast() {
        for order in orderings(spec()) {
            XCTAssertEqual(order.filter { $0 == "close" }.count, 1, "a second close could not also be last")
            XCTAssertEqual(order.last, "close")
        }
    }

    func testEveryDeclaredOpStillAppearsAtLeastOnce() {
        for order in orderings(spec()) {
            XCTAssertEqual(Set(order), ["push", "pull", "close"])
        }
    }

    func testOrderingsAreDistinct() {
        let explored = orderings(spec())

        XCTAssertEqual(
            Set(explored.map { $0.joined(separator: ",") }).count,
            explored.count,
            "interchangeable occurrences of one label must not enumerate the same ordering twice"
        )
    }

    /// The golden cassette is recorded over the maximal sequence, so a repeated op's second seam read
    /// has a recorded value to replay. Without that it falls back to live and the verdict abstains.
    func testARepeatedSeamReadStillReplaysFromThePlan() throws {
        let spec = Spec<Ledger>("ledger.seamed")
            .system { _ in Ledger() }
            .operations {
                Op("push") { sut, seams in sut.push("push-\(seams.int("size", default: 1))") }
                Op("close") { $0.push("close") }.last()
            }
            .vary {
                Seam("size", .int(1 ... 9))
                Ordering(max: 50)
            }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("repetition-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try spec.record(to: url)

        let verdict = try spec.verify(replayingContentsOf: url)
        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
        XCTAssertTrue(verdict.coverage.unrecordedReach.isEmpty, verdict.report())
    }
}
