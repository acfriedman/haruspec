import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
@testable import HaruspecTrace
import XCTest

// Settle points: the gaps between operations where a capture lets held work land. Two ports bracket
// the change. `StuckFeed` only misbehaves once an earlier refresh has landed, which a capture that
// runs every operation first never reaches; `CachedTally` only misbehaves before anything has
// landed, which a capture that drains after every operation never reaches. Exploring settle
// schedules catches both in one sweep.

// MARK: - The seams the project owns

@Haruspec(schedules: .serial)
protocol SettleSerialQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
    func sync(_ work: () -> Void)
    func after(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void)
}

@Haruspec(schedules: .main)
protocol SettleMainQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

// MARK: - A refresh guarded by an in-flight flag

@Haruspec
protocol SettleFeed: AnyObject {
    init(queue: any SettleSerialQueue, main: any SettleMainQueue, center: NotificationCenter)
    func refresh()
}

final class LegacySettleFeed: SettleFeed, @unchecked Sendable {
    private let queue: any SettleSerialQueue
    private let main: any SettleMainQueue
    private let center: NotificationCenter
    private var isLoading = false
    private var page = 0

    init(queue: any SettleSerialQueue, main: any SettleMainQueue, center: NotificationCenter) {
        self.queue = queue
        self.main = main
        self.center = center
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        queue.async { [self] in
            let next = page + 1
            main.async { [self] in
                page = next
                isLoading = false
                center.post(name: .init("SettleFeedDidLoad"), object: nil, userInfo: ["page": next])
            }
        }
    }
}

/// The port drops the line that clears the flag: every refresh after the first does nothing.
final class StuckSettleFeed: SettleFeed, @unchecked Sendable {
    private let queue: any SettleSerialQueue
    private let main: any SettleMainQueue
    private let center: NotificationCenter
    private var isLoading = false
    private var page = 0

    init(queue: any SettleSerialQueue, main: any SettleMainQueue, center: NotificationCenter) {
        self.queue = queue
        self.main = main
        self.center = center
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        queue.async { [self] in
            let next = page + 1
            main.async { [self] in
                page = next
                center.post(name: .init("SettleFeedDidLoad"), object: nil, userInfo: ["page": next])
            }
        }
    }
}

// MARK: - A total read through the queue, or from a cache main fills

@Haruspec
protocol SettleTally: AnyObject {
    init(queue: any SettleSerialQueue, main: any SettleMainQueue)
    func add(_ amount: Int)
    func total() -> Int
}

final class LegacySettleTally: SettleTally, @unchecked Sendable {
    private let queue: any SettleSerialQueue
    private var sum = 0

    init(queue: any SettleSerialQueue, main _: any SettleMainQueue) {
        self.queue = queue
    }

    func add(_ amount: Int) {
        queue.async { [self] in sum += amount }
    }

    func total() -> Int {
        var value = 0
        queue.sync { value = sum }
        return value
    }
}

/// The port answers from a cache the main queue fills: right once things settle, stale before.
final class CachedSettleTally: SettleTally, @unchecked Sendable {
    private let queue: any SettleSerialQueue
    private let main: any SettleMainQueue
    private var sum = 0
    private var cached = 0

    init(queue: any SettleSerialQueue, main: any SettleMainQueue) {
        self.queue = queue
        self.main = main
    }

    func add(_ amount: Int) {
        queue.async { [self] in
            sum += amount
            let snapshot = sum
            main.async { [self] in cached = snapshot }
        }
    }

    func total() -> Int {
        cached
    }
}

// MARK: - A debounced search, and a subject whose work never crosses a gap

@Haruspec
protocol SettleSearch: AnyObject {
    init(queue: any SettleSerialQueue, center: NotificationCenter)
    func search(_ text: String)
}

final class DebouncedSettleSearch: SettleSearch, @unchecked Sendable {
    private let queue: any SettleSerialQueue
    private let center: NotificationCenter
    private var generation = 0

    init(queue: any SettleSerialQueue, center: NotificationCenter) {
        self.queue = queue
        self.center = center
    }

    func search(_ text: String) {
        generation += 1
        let armed = generation
        queue.after(0.3) { [self] in
            if armed == generation {
                center.post(name: .init("SettleSearchDidRun"), object: nil, userInfo: ["query": text])
            }
        }
    }
}

@Haruspec
protocol SettleCounter: AnyObject {
    init(queue: any SettleSerialQueue)
    func bump()
    func count() -> Int
}

/// Every write lands inside its own operation, so no gap ever has anything to settle.
final class SyncSettleCounter: SettleCounter, @unchecked Sendable {
    private let queue: any SettleSerialQueue
    private var value = 0

    init(queue: any SettleSerialQueue) {
        self.queue = queue
    }

    func bump() {
        queue.sync { value += 1 }
    }

    func count() -> Int {
        var current = 0
        queue.sync { current = value }
        return current
    }
}

// MARK: - Tests

final class SettlePointTests: XCTestCase {
    private func feed(on conformer: any SettleFeed.Type) -> BaselinedSpec<any SettleFeed> {
        Spec<any SettleFeed>("settle.feed")
            .vary {
                Ordering(max: 10)
                Budget(runs: 20)
            }
            .baselined(on: conformer)
    }

    private func verdict(_ spec: BaselinedSpec<some Any>, _ candidate: Any.Type) async -> SpecVerdict {
        await spec.verify(candidate: spec.spec.constructing(candidate))
    }

    private func labels(_ trace: Trace, kind: EventKind) -> [String] {
        trace.events.filter { $0.kind == kind }.map(\.label)
    }

    // MARK: Verdicts

    func testAPortThatOnlyFailsOnceEarlierWorkHasLandedIsCaught() async {
        let result = await verdict(feed(on: LegacySettleFeed.self), StuckSettleFeed.self)

        XCTAssertEqual(result.verdict, .diverged, result.report())
        let failing = result.failingOrder ?? []
        XCTAssertEqual(operationLabels(failing).count, 2, "two refreshes are the shortest failure: \(failing)")
        XCTAssertEqual(
            failing.compactMap(Settle.init(stepLabel:)).count,
            1,
            "the shrunk order keeps the one gap that lets the first refresh land: \(failing)"
        )
    }

    func testAPortThatOnlyFailsBeforeAnythingHasLandedIsStillCaught() async {
        let spec = Spec<any SettleTally>("settle.tally")
            .vary {
                Ordering(max: 10)
                Budget(runs: 20)
            }
            .baselined(on: LegacySettleTally.self)

        let result = await verdict(spec, CachedSettleTally.self)

        XCTAssertEqual(result.verdict, .diverged, "the all-held corner still runs: \(result.report())")
    }

    func testTheParityPortHoldsUnderEverySettleSchedule() async {
        let result = await verdict(feed(on: LegacySettleFeed.self), LegacySettleFeed.self)

        XCTAssertEqual(result.verdict, .equivalent, result.report())
        XCTAssertGreaterThan(result.exploration.settleSchedulesPerOrdering, 1)
        XCTAssertTrue(result.exploration.summary.contains("settle schedules"), result.exploration.summary)
    }

    func testASubjectThatNeverHoldsWorkAcrossAGapExploresNoSettleSchedules() async {
        let spec = Spec<any SettleCounter>("settle.counter")
            .vary {
                Ordering(max: 10)
            }
            .baselined(on: SyncSettleCounter.self)

        let result = await verdict(spec, SyncSettleCounter.self)

        XCTAssertEqual(result.exploration.settleSchedulesPerOrdering, 1)
        XCTAssertEqual(result.exploration.settledOrderingsExplored, result.exploration.orderingsExplored)
        XCTAssertFalse(result.exploration.summary.contains("settle"), result.exploration.summary)
    }

    // MARK: The capture

    func testASettleStepTakesNoOperationPosition() async throws {
        let spec = feed(on: LegacySettleFeed.self)
        let refresh = try XCTUnwrap(spec.spec.operations.first)

        let trace = await spec.spec.capture(
            make: spec.baseline,
            order: [refresh, .settling(.elapsed), refresh],
            cassette: Cassette()
        )

        let positions = Set(trace.events.compactMap(\.op?.position))
        XCTAssertEqual(positions, [0, 1], "an op is numbered the same under every settle schedule")
    }

    func testAnElapsedGapLetsTheFirstRefreshLandBeforeTheSecond() async throws {
        let spec = feed(on: LegacySettleFeed.self)
        let refresh = try XCTUnwrap(spec.spec.operations.first)

        let held = await spec.spec.capture(make: spec.baseline, order: [refresh, refresh], cassette: Cassette())
        let elapsed = await spec.spec.capture(
            make: spec.baseline,
            order: [refresh, .settling(.elapsed), refresh],
            cassette: Cassette()
        )

        XCTAssertEqual(
            labels(held, kind: .notification),
            ["SettleFeedDidLoad"],
            "the second refresh met the flag still set"
        )
        XCTAssertEqual(labels(elapsed, kind: .notification), ["SettleFeedDidLoad", "SettleFeedDidLoad"])
    }

    func testAReadyGapKeepsTheClockSoADebounceStillCollapses() async throws {
        let spec = Spec<any SettleSearch>("settle.search") {
            Amend("search").varying("text", over: .oneOf("c", "co"))
        }
        .baselined(on: DebouncedSettleSearch.self)
        let search = try XCTUnwrap(spec.spec.operations.first)

        let ready = await spec.spec.capture(
            make: spec.baseline,
            order: [search, .settling(.ready), search],
            cassette: Cassette()
        )
        let elapsed = await spec.spec.capture(
            make: spec.baseline,
            order: [search, .settling(.elapsed), search],
            cassette: Cassette()
        )

        XCTAssertEqual(labels(ready, kind: .notification).count, 1, "the timer was still waiting at the second input")
        XCTAssertEqual(labels(elapsed, kind: .notification).count, 2, "the user paused, so the first search ran")
    }

    // MARK: Record and replay

    func testARecordedPlanCarriesItsSettleSchedules() async {
        let plan = await feed(on: LegacySettleFeed.self).record()

        XCTAssertTrue(
            plan.probes.contains { $0.ordering.contains(Settle.elapsed.stepLabel) },
            "a probe's ordering carries its settle steps"
        )
        let parity = await feed(on: LegacySettleFeed.self).verify(replaying: plan)
        XCTAssertEqual(parity.verdict, .equivalent, parity.report())
        XCTAssertTrue(parity.result.coverage.gaps.isEmpty, "a settle step is replayable, never a missing op")

        let stuck = await feed(on: StuckSettleFeed.self).verify(replaying: plan)
        XCTAssertEqual(stuck.verdict, .diverged, stuck.report())
        XCTAssertNotNil(stuck.failingOrder?.first { Settle(stepLabel: $0) != nil })
    }
}
