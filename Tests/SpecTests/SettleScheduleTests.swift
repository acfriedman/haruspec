@testable import HaruspecSpec
@testable import HaruspecTrace
import XCTest

// Which settle schedules an ordering runs under, how a shrink folds them back, and how the budget
// splits once they are an axis.

final class SettleScheduleTests: XCTestCase {
    func testAnOrderingWithNoGapsHasOnlyTheEmptySchedule() {
        XCTAssertEqual(SettleSchedules.sample(gaps: 0, max: 4, seed: 1), [[]])
    }

    func testTheCornersRunFirstThenSingleFlips() {
        let schedules = SettleSchedules.sample(gaps: 3, max: 4, seed: 1)

        XCTAssertEqual(schedules, [
            [nil, nil, nil],
            [.elapsed, .elapsed, .elapsed],
            [.elapsed, nil, nil],
            [nil, .elapsed, nil]
        ])
    }

    func testOneGapHasThreeSchedulesWhateverTheBudget() {
        XCTAssertEqual(SettleSchedules.sample(gaps: 1, max: 10, seed: 1), [[nil], [.elapsed], [.ready]])
    }

    func testABudgetPastTheSpaceTakesEveryScheduleOnce() {
        let schedules = SettleSchedules.sample(gaps: 3, max: 100, seed: 1)

        XCTAssertEqual(schedules.count, 27)
        XCTAssertEqual(Set(schedules).count, 27)
    }

    func testAShrinkTrialFoldsBackIntoOneSettleStepPerGap() {
        let first = Op<Int>("a") { _ in }
        let second = Op<Int>("b") { _ in }
        let trial: [Op<Int>] = [
            .settling(.ready),
            first,
            .settling(.ready),
            .settling(.elapsed),
            second,
            .settling(.elapsed)
        ]

        XCTAssertEqual(normalizedSettles(trial).map(\.label), ["a", "settle:elapsed", "b"])
    }

    func testASettleScheduleInterleavesBetweenOperations() {
        let first = Op<Int>("a") { _ in }

        XCTAssertEqual(
            interleaving([nil, .ready], into: [first, first, first]).map(\.label),
            ["a", "a", "settle:ready", "a"]
        )
    }

    func testWithoutSettleSchedulesTheBudgetSplitsAsBefore() {
        let three = ExplorationBudget.split(orderingCap: 100, scheduleCap: 1, variants: 64, budget: 12)
        let two = ExplorationBudget.split(orderingCap: 100, variants: 64, budget: 12)

        XCTAssertEqual(three.orderings, two.orderings)
        XCTAssertEqual(three.schedules, 1)
        XCTAssertEqual(three.variants, two.variants)
    }

    func testAnUnboundedRunTakesEveryAxisWhole() {
        let split = ExplorationBudget.split(orderingCap: 50, scheduleCap: 4, variants: 64, budget: nil)

        XCTAssertEqual(split.orderings, 50)
        XCTAssertEqual(split.schedules, 4)
        XCTAssertEqual(split.variants, 64)
    }

    func testABudgetKeepsBothCornersAndStaysWithinItself() {
        for budget in [20, 200, 1200, 5000] {
            let split = ExplorationBudget.split(orderingCap: 50, scheduleCap: 4, variants: 64, budget: budget)

            XCTAssertGreaterThanOrEqual(split.schedules, 2, "budget \(budget)")
            XCTAssertLessThanOrEqual(split.orderings * split.schedules * split.variants, budget, "budget \(budget)")
        }
    }
}
