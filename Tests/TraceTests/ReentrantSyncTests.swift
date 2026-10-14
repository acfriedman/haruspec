import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// A sync onto the serial queue running the caller deadlocks under Grand Central Dispatch, so the
/// backlog refuses it rather than run it inline. Each test asks from where the sync would be made.
final class ReentrantSyncTests: XCTestCase {
    private final class Queue {}

    private func refusal(onto queue: Queue, _ discipline: ScheduleDiscipline = .serial) -> String? {
        WorkBacklog.syncRefusal(onto: queue, label: "DepotQueue", discipline: discipline)
    }

    func testASerialQueuesOwnWorkSyncingOntoItIsRefused() async throws {
        let backlog = WorkBacklog()
        let queue = Queue()
        nonisolated(unsafe) var found: String?

        backlog.enqueue(on: queue, label: "DepotQueue", discipline: .serial) { found = self.refusal(onto: queue) }
        await backlog.drain(recorder: nil)

        let message = try XCTUnwrap(found)
        XCTAssertTrue(message.contains("A sync onto queue(serial):DepotQueue from work already running"), message)
        XCTAssertTrue(message.contains("deadlocks"), message)
    }

    func testASyncInsideASyncOnTheSameQueueIsRefused() {
        let backlog = WorkBacklog()
        let queue = Queue()
        nonisolated(unsafe) var found: String?

        backlog.runSync(on: queue, label: "DepotQueue", discipline: .serial) { found = self.refusal(onto: queue) }

        XCTAssertNotNil(found)
    }

    func testHeldWorkMaySyncOntoAnotherSerialQueue() async {
        let backlog = WorkBacklog()
        let other = Queue()
        nonisolated(unsafe) var found: String? = "unset"

        backlog.enqueue(on: Queue(), label: "DepotQueue", discipline: .serial) { found = self.refusal(onto: other) }
        await backlog.drain(recorder: nil)

        XCTAssertNil(found)
    }

    func testAConcurrentQueueMaySyncOntoItself() async {
        let backlog = WorkBacklog()
        let queue = Queue()
        nonisolated(unsafe) var found: String? = "unset"

        backlog.enqueue(on: queue, label: "DepotQueue", discipline: .concurrent) {
            found = self.refusal(onto: queue, .concurrent)
        }
        await backlog.drain(recorder: nil)

        XCTAssertNil(found)
    }

    func testASyncFromOutsideHeldWorkRuns() {
        XCTAssertNil(refusal(onto: Queue()))
    }
}
