import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// The project's thread seams, stamped. A subject takes its queues in its `init` like any
// collaborator; production hands it a real `DispatchQueue`, and a capture hands it the stamped
// double, which holds the work for the engine to run in one deterministic order.

// MARK: - The seams the project owns

/// The depot's own serial queue: every shape a scheduling protocol may declare.
@Haruspec(schedules: .serial)
protocol DepotQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
    func after(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void)
    func notify(_ group: DispatchGroup, _ work: @escaping @Sendable () -> Void)
    func sync(_ work: () -> Void)
}

/// The main queue, which the depot announces on.
@Haruspec(schedules: .main)
protocol MainQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

/// A concurrent queue, for the port that drops the serial contract.
@Haruspec(schedules: .concurrent)
protocol BackgroundQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

// Production: Apple's queues, unchanged. Each requirement forwards to the member it names.
extension DispatchQueue: DepotQueue, MainQueue, BackgroundQueue {
    func async(_ work: @escaping @Sendable () -> Void) {
        async(execute: work)
    }

    func after(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        asyncAfter(deadline: .now() + delay, execute: work)
    }

    func notify(_ group: DispatchGroup, _ work: @escaping @Sendable () -> Void) {
        group.notify(queue: self, execute: work)
    }

    func sync(_ work: () -> Void) {
        sync(execute: work)
    }
}

// MARK: - The subject

/// The pasted interface, init included, so construction derives: each queue parameter resolves to
/// the stamped double serving its protocol.
@Haruspec
protocol Depot: AnyObject {
    init(queue: any DepotQueue, main: any MainQueue, center: NotificationCenter)
    func post(amount: Int)
    var balance: Int { get }
}

/// The baseline: posts on its serial queue, announces on main, reads through `sync`.
final class LegacyDepot: Depot, @unchecked Sendable {
    private let queue: any DepotQueue
    private let main: any MainQueue
    private let center: NotificationCenter
    private var total = 0

    init(queue: any DepotQueue, main: any MainQueue, center: NotificationCenter) {
        self.queue = queue
        self.main = main
        self.center = center
    }

    func post(amount: Int) {
        queue.async { [self] in
            total += amount
            let announced = total
            main.async { [center] in
                center.post(name: .init("ParcelDidPost"), object: nil, userInfo: ["total": announced])
            }
        }
    }

    var balance: Int {
        var read = 0
        queue.sync { read = total }
        return read
    }
}

/// A faithful port, built the same way.
final class SwiftDepot: Depot, @unchecked Sendable {
    private let queue: any DepotQueue
    private let main: any MainQueue
    private let center: NotificationCenter
    private var total = 0

    init(queue: any DepotQueue, main: any MainQueue, center: NotificationCenter) {
        self.queue = queue
        self.main = main
        self.center = center
    }

    func post(amount: Int) {
        queue.async { [self] in
            total += amount
            let announced = total
            main.async { [center] in
                center.post(name: .init("ParcelDidPost"), object: nil, userInfo: ["total": announced])
            }
        }
    }

    var balance: Int {
        var read = 0
        queue.sync { read = total }
        return read
    }
}

/// A port that announces from its own queue instead of main: the delivery contract dropped.
final class OffMainDepot: Depot, @unchecked Sendable {
    private let queue: any DepotQueue
    private let center: NotificationCenter
    private var total = 0

    init(queue: any DepotQueue, main _: any MainQueue, center: NotificationCenter) {
        self.queue = queue
        self.center = center
    }

    func post(amount: Int) {
        queue.async { [self] in
            total += amount
            center.post(name: .init("ParcelDidPost"), object: nil, userInfo: ["total": total])
        }
    }

    var balance: Int {
        var read = 0
        queue.sync { read = total }
        return read
    }
}

// MARK: - Tests

final class SchedulingStampTests: XCTestCase {
    private var spec: BaselinedSpec<any Depot> {
        Spec<any Depot>("depot.scheduled", derivedFrom: DerivedDepot.self)
            .vary {
                Ordering(max: 4)
                Budget(runs: 30)
            }
            .baselined(on: LegacyDepot.self)
    }

    // MARK: The double holds the work

    func testTheDoubleServesItsProtocolAndHoldsWhatItIsHanded() async {
        let recorder = TraceRecorder(name: "held")
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())
        let queue = context.double(DoubleDepotQueue.self)
        nonisolated(unsafe) var ran = false

        XCTAssertTrue(DoubleDepotQueue.servedBoundaries.contains { $0 == DepotQueue.self })
        TraceContext.$current.withValue(recorder) {
            queue.async { ran = true }
        }
        XCTAssertFalse(ran, "nothing runs at the enqueue")
        XCTAssertEqual(context.backlog.pendingCount, 1)

        await context.backlog.drain(recorder: recorder)
        XCTAssertTrue(ran)
    }

    func testEachShapeReachesTheBacklog() async {
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())
        let queue = context.double(DoubleDepotQueue.self)
        let group = DispatchGroup()
        nonisolated(unsafe) var order: [String] = []

        group.enter()
        queue.notify(group) { order.append("joined") }
        queue.after(1) { order.append("delayed") }
        queue.async {
            order.append("async")
            group.leave()
        }
        queue.sync { order.append("sync") }
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(order, ["async", "sync", "joined", "delayed"])
    }

    // MARK: Production runs on Apple's queue

    func testTheProductionConformanceIsApplesQueue() {
        let queue: any DepotQueue = DispatchQueue(label: "depot.production")
        let done = expectation(description: "ran")

        queue.async { done.fulfill() }

        wait(for: [done], timeout: 2)
    }

    // MARK: The differential

    func testDerivedConstructionResolvesEachQueueToItsDouble() async throws {
        let verdict = try await spec.check(SwiftDepot.self)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testHeldWorkRecordsOnTheDomainItWasHandedTo() async {
        let trace = await spec.spec.capture(
            make: spec.baseline,
            order: spec.spec.operations.filter { $0.label == "post" },
            cassette: Cassette()
        )

        let announced = trace.events.first { $0.kind == .notification }
        XCTAssertEqual(announced?.domain, .main)
    }

    func testAnAnnouncementMovedOffMainDiverges() async throws {
        let verdict = try await spec.check(OffMainDepot.self, expecting: .diverged)

        XCTAssertTrue(verdict.report().contains("ran on a different domain"), verdict.report())
    }

    func testARecordedPlanReplaysStably() async {
        let plan = await spec.record()
        let verdict = await spec.verify(replaying: plan)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
        XCTAssertTrue(verdict.stability.isStable, "held work runs in one order every pass")
    }
}
