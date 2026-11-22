import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
@testable import HaruspecTrace
import XCTest

// A subject that takes two queues of one stamped protocol names each where it is injected. The name is
// the domain, so a port that moves work from one to the other is caught; left unnamed, the capture
// refuses rather than read their order against each other as a guarantee.

// MARK: - Subjects

@Haruspec(schedules: .serial)
protocol JournalQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

@Haruspec
protocol Journal: AnyObject {
    func save(_ entry: String)
}

/// Records on its state queue, writes on its disk queue.
final class TwoQueueJournal: Journal, @unchecked Sendable {
    private let state: any JournalQueue
    private let disk: any JournalQueue
    private let center: NotificationCenter

    init(state: any JournalQueue, disk: any JournalQueue, center: NotificationCenter) {
        self.state = state
        self.disk = disk
        self.center = center
    }

    func save(_ entry: String) {
        state.async { [center] in center.post(name: .init("Recorded"), object: nil, userInfo: ["entry": entry]) }
        disk.async { [center] in center.post(name: .init("Written"), object: nil, userInfo: ["entry": entry]) }
    }
}

/// The port moves the write onto the state queue, behind every state update.
final class MovedWriteJournal: Journal, @unchecked Sendable {
    private let state: any JournalQueue
    private let center: NotificationCenter

    init(state: any JournalQueue, disk _: any JournalQueue, center: NotificationCenter) {
        self.state = state
        self.center = center
    }

    func save(_ entry: String) {
        state.async { [center] in center.post(name: .init("Recorded"), object: nil, userInfo: ["entry": entry]) }
        state.async { [center] in center.post(name: .init("Written"), object: nil, userInfo: ["entry": entry]) }
    }
}

// MARK: - Tests

final class NamedQueueTests: XCTestCase {
    func testNamedQueuesAreEquivalentToThemselves() async {
        let verdict = await journal.verify { context in
            TwoQueueJournal(
                state: context.double(DoubleJournalQueue.self, label: "state"),
                disk: context.double(DoubleJournalQueue.self, label: "io"),
                center: context.notifications
            )
        }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testWorkMovedBetweenNamedQueuesDiverges() async {
        let verdict = await journal.verify { context in
            MovedWriteJournal(
                state: context.double(DoubleJournalQueue.self, label: "state"),
                disk: context.double(DoubleJournalQueue.self, label: "io"),
                center: context.notifications
            )
        }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(
            verdict.report().contains("Written: ran on a different domain (queue(serial):io → queue(serial):state)"),
            verdict.report()
        )
    }

    private var journal: BaselinedSpec<any Journal> {
        Spec<any Journal>("journal.named")
            .operations { Op("save") { $0.save("a") } }
            .baselined { context in
                TwoQueueJournal(
                    state: context.double(DoubleJournalQueue.self, label: "state"),
                    disk: context.double(DoubleJournalQueue.self, label: "io"),
                    center: context.notifications
                )
            }
    }

    func testAnUnnamedQueueStillRecordsAsItsProtocol() async {
        let context = context()
        let recorder = TraceRecorder(name: "unnamed")
        let queue = context.double(DoubleJournalQueue.self)

        queue.async { Haruspec.marker("ran") }
        await context.backlog.drain(recorder: recorder)

        XCTAssertEqual(recorder.trace().events.first?.domain, .queue("JournalQueue", serial: true))
    }

    func testTheRefusalSpellsHowEachKindOfQueueIsNamed() {
        let context = context()
        let domain = ConcurrencyDomain.queue("uploads", serial: true)
        let message = { (first: AnyObject, second: AnyObject) in
            DomainOwners.conflict(on: domain, between: first, and: second)
        }

        let doubles = message(context.double(DoubleJournalQueue.self), context.double(DoubleJournalQueue.self))
        let queues = message(context.operationQueue(.serial("uploads")), context.operationQueue(.serial("uploads")))
        let schedulers = message(
            context.scheduler(.serial("uploads")).identity,
            context.scheduler(.serial("uploads")).identity
        )

        XCTAssertTrue(doubles.contains(#"context.double(DoubleJournalQueue.self, label: "io")"#), doubles)
        XCTAssertTrue(doubles.contains("a DoubleJournalQueue and a DoubleJournalQueue"), doubles)
        XCTAssertTrue(queues.contains(#"context.operationQueue(.serial("state"))"#), queues)
        XCTAssertTrue(queues.contains("a HeldOperationQueue and a HeldOperationQueue"), queues)
        XCTAssertTrue(schedulers.contains(#"context.scheduler(.serial("io"))"#), schedulers)
        XCTAssertTrue(schedulers.contains("a HeldScheduler and a HeldScheduler"), schedulers)
    }

    private func context() -> SeamContext {
        SeamContext(notifications: NotificationCenter(), cassette: Cassette())
    }
}
