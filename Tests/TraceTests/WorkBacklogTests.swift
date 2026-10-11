import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// The capture's controlled scheduler. Work a subject hands to its scheduling seam is held here and
/// run by the engine, one item at a time, in one order: the same order every run.
///
/// These drive the backlog directly, as a stamped scheduling double does (`DoubleCartQueue` hands
/// each `async` to ``WorkBacklog/enqueue(on:label:discipline:after:notifying:_:)``).
final class WorkBacklogTests: XCTestCase {
    /// Stands in for a scheduling double: the identity `sync` drains by.
    private final class Queue {}

    private func events(_ recorder: TraceRecorder) -> [TraceEvent] {
        recorder.trace().events
    }

    private func labels(_ recorder: TraceRecorder) -> [String] {
        events(recorder).map(\.label)
    }

    // MARK: Holding and draining

    /// Nothing runs at the enqueue: the work is held until the engine drains, and then runs in the
    /// order it was handed over.
    func testHeldWorkRunsAtTheDrainInEnqueueOrder() async {
        let recorder = TraceRecorder(name: "order")
        let backlog = WorkBacklog()
        let queue = Queue()

        TraceContext.$current.withValue(recorder) {
            for index in 1 ... 3 {
                backlog.enqueue(on: queue, label: "CartQueue", discipline: .serial) {
                    Haruspec.marker("work-\(index)")
                }
            }
            Haruspec.marker("enqueued")
        }
        XCTAssertEqual(backlog.pendingCount, 3)

        let settled = await backlog.drain(recorder: recorder)

        XCTAssertTrue(settled)
        XCTAssertEqual(labels(recorder), ["enqueued", "work-1", "work-2", "work-3"])
    }

    /// The drain rebinds the recorder, so work enqueued inside the window records after the window
    /// has closed: it is reached however the subject handed it off.
    func testHeldWorkRecordsIntoTheCapturesRecorder() async {
        let recorder = TraceRecorder(name: "reach")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            backlog.enqueue(on: Queue(), label: "CartQueue", discipline: .serial) { Haruspec.marker("late") }
        }
        XCTAssertTrue(labels(recorder).isEmpty)

        await backlog.drain(recorder: recorder)

        XCTAssertEqual(labels(recorder), ["late"])
    }

    /// Work enqueued while held work runs joins the end of the backlog and runs in the same drain.
    func testWorkEnqueuedByHeldWorkRunsInTheSameDrain() async {
        let recorder = TraceRecorder(name: "chain")
        let backlog = WorkBacklog()
        let queue = Queue()

        TraceContext.$current.withValue(recorder) {
            backlog.enqueue(on: queue, label: "Q", discipline: .serial) {
                Haruspec.marker("outer")
                backlog.enqueue(on: queue, label: "Q", discipline: .serial) { Haruspec.marker("inner") }
            }
        }
        await backlog.drain(recorder: recorder)

        XCTAssertEqual(labels(recorder), ["outer", "inner"])
        XCTAssertEqual(backlog.pendingCount, 0)
    }

    // MARK: Domains

    /// Held work runs on the draining task, but it ran *as* the queue it was handed to, with the
    /// discipline the stamp declared.
    func testHeldWorkRecordsTheDomainOfTheSeamItWasHandedTo() async {
        let recorder = TraceRecorder(name: "domains")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            backlog.enqueue(on: Queue(), label: "CartQueue", discipline: .serial) { Haruspec.marker("serial") }
            backlog.enqueue(on: Queue(), label: "Background", discipline: .concurrent) { Haruspec.marker("wide") }
            backlog.enqueue(on: Queue(), label: "MainQueue", discipline: .main) { Haruspec.marker("main") }
        }
        await backlog.drain(recorder: recorder)

        let byLabel = Dictionary(uniqueKeysWithValues: events(recorder).map { ($0.label, $0.domain) })
        XCTAssertEqual(byLabel["serial"], .queue("CartQueue", serial: true))
        XCTAssertEqual(byLabel["wide"], .queue("Background", serial: false))
        XCTAssertEqual(byLabel["main"], .main)
    }

    /// Main-queue work runs on the main thread, as it would have: code inside it may assume main.
    func testMainQueueWorkRunsOnTheMainThread() async {
        let backlog = WorkBacklog()
        nonisolated(unsafe) var ranOnMain: Bool?

        backlog.enqueue(on: Queue(), label: "MainQueue", discipline: .main) { ranOnMain = Thread.isMainThread }
        await backlog.drain(recorder: nil)

        XCTAssertEqual(ranOnMain, true)
    }

    // MARK: Happens-before

    /// The enqueueing call is read at the enqueue, the only moment both ends of the edge are in hand,
    /// and the work's first event claims it. Program order carries the rest of the work.
    func testHeldWorkNamesTheCallThatEnqueuedIt() async throws {
        let recorder = TraceRecorder(name: "spawn")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            recorder.call("Cart.checkout")
            backlog.enqueue(on: Queue(), label: "CartQueue", discipline: .serial) {
                Haruspec.marker("first")
                Haruspec.marker("second")
            }
            recorder.ret("Cart.checkout")
        }
        await backlog.drain(recorder: recorder)

        let checkout = try XCTUnwrap(events(recorder).first { $0.label == "Cart.checkout" })
        XCTAssertEqual(events(recorder).first { $0.label == "first" }?.spawnedBy, checkout.seq)
        XCTAssertNil(events(recorder).first { $0.label == "second" }?.spawnedBy)
    }

    /// Held work is attributed to the op that enqueued it, not to whichever op is running when the
    /// engine gets to it.
    func testHeldWorkIsAttributedToTheOpThatEnqueuedIt() async {
        let recorder = TraceRecorder(name: "ops")
        let backlog = WorkBacklog()
        let enqueuing = OpIdentity(label: "add", position: 0)

        TraceContext.$current.withValue(recorder) {
            TraceContext.$currentOp.withValue(enqueuing) {
                backlog.enqueue(on: Queue(), label: "Q", discipline: .serial) { Haruspec.marker("deferred") }
            }
        }
        await TraceContext.$currentOp.withValue(OpIdentity(label: "checkout", position: 1)) {
            await backlog.drain(recorder: recorder)
        }

        XCTAssertEqual(events(recorder).first?.op, enqueuing)
    }

    // MARK: sync

    /// A `sync` runs after the work already held for its queue, then inline: the serial-queue
    /// contract that a read after a write depends on.
    func testSyncRunsTheQueuesHeldWorkFirst() {
        let backlog = WorkBacklog()
        let queue = Queue()
        let other = Queue()
        nonisolated(unsafe) var order: [String] = []

        backlog.enqueue(on: queue, label: "Q", discipline: .serial) { order.append("write") }
        backlog.enqueue(on: other, label: "Other", discipline: .serial) { order.append("other") }
        backlog.runSync(on: queue, label: "Q", discipline: .serial) { order.append("read") }

        XCTAssertEqual(order, ["write", "read"], "another queue's work is not this queue's to run")
        XCTAssertEqual(backlog.pendingCount, 1)
    }

    func testSyncWorkRecordsTheQueuesDomain() {
        let recorder = TraceRecorder(name: "sync")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            backlog.runSync(on: Queue(), label: "CartQueue", discipline: .serial) { Haruspec.marker("read") }
        }

        XCTAssertEqual(events(recorder).first?.domain, .queue("CartQueue", serial: true))
    }

    // MARK: Virtual time

    /// Delayed work runs only once nothing else is ready, in deadline order, however it was enqueued.
    func testDelayedWorkRunsAfterReadyWorkInDeadlineOrder() async {
        let recorder = TraceRecorder(name: "time")
        let backlog = WorkBacklog()
        let queue = Queue()

        TraceContext.$current.withValue(recorder) {
            backlog.enqueue(on: queue, label: "Q", discipline: .main, after: 0.5) { Haruspec.marker("late") }
            backlog.enqueue(on: queue, label: "Q", discipline: .main, after: 0.3) { Haruspec.marker("soon") }
            backlog.enqueue(on: queue, label: "Q", discipline: .main) { Haruspec.marker("now") }
        }
        await backlog.drain(recorder: recorder)

        XCTAssertEqual(labels(recorder), ["now", "timer", "soon", "timer", "late"])
        let delays = events(recorder).filter { $0.kind == .timer }.map(\.payload)
        XCTAssertEqual(delays, [.int(300), .int(500)], "each fire records the delay it was handed")
    }

    /// A ready settle point runs what is ready, and what that hands on, but never moves the clock: a
    /// delayed item stays held until an elapsed one.
    func testAReadySettleRunsReadyWorkAndLeavesTheClock() async {
        let recorder = TraceRecorder(name: "settle")
        let backlog = WorkBacklog()
        let queue = Queue()

        TraceContext.$current.withValue(recorder) {
            backlog.enqueue(on: queue, label: "Q", discipline: .main, after: 0.3) { Haruspec.marker("late") }
            backlog.enqueue(on: queue, label: "Q", discipline: .main) {
                Haruspec.marker("now")
                backlog.enqueue(on: queue, label: "Q", discipline: .main) { Haruspec.marker("handed on") }
            }
        }
        let settled = await backlog.settle(.ready, recorder: recorder)

        XCTAssertTrue(settled)
        XCTAssertEqual(labels(recorder), ["now", "handed on"])
        XCTAssertEqual(backlog.pendingCount, 1, "the timer is still waiting")

        await backlog.settle(.elapsed, recorder: recorder)
        XCTAssertEqual(labels(recorder), ["now", "handed on", "timer", "late"])
    }

    /// A debounce, as Combine builds one: each input re-arms a timer, and only the timer armed by the
    /// last input finds no newer one when it fires. The quiet period arrives at the settled point.
    func testADebounceFiresOnceForTheLastInput() async {
        let recorder = TraceRecorder(name: "debounce")
        let backlog = WorkBacklog()
        let queue = Queue()
        nonisolated(unsafe) var generation = 0

        TraceContext.$current.withValue(recorder) {
            for input in ["c", "co", "cof"] {
                generation += 1
                let armed = generation
                backlog.enqueue(on: queue, label: "Q", discipline: .main, after: 0.3) {
                    if armed == generation {
                        Haruspec.marker("search \(input)")
                    }
                }
            }
        }
        await backlog.drain(recorder: recorder)

        XCTAssertEqual(labels(recorder).filter { $0 != "timer" }, ["search cof"])
    }

    // MARK: Groups

    /// A `notify` is held until its group empties. The group is probed without blocking, so the work
    /// that leaves it runs first, on the same task.
    func testNotifyWaitsForTheGroupToEmpty() async {
        let recorder = TraceRecorder(name: "group")
        let backlog = WorkBacklog()
        let queue = Queue()
        let group = DispatchGroup()

        TraceContext.$current.withValue(recorder) {
            group.enter()
            group.enter()
            backlog.enqueue(on: queue, label: "Q", discipline: .main, notifying: group) { Haruspec.marker("joined") }
            for branch in ["a", "b"] {
                backlog.enqueue(on: queue, label: "Q", discipline: .concurrent) {
                    Haruspec.marker("branch \(branch)")
                    group.leave()
                }
            }
        }
        let settled = await backlog.drain(recorder: recorder)

        XCTAssertTrue(settled)
        XCTAssertEqual(labels(recorder), ["branch a", "branch b", "joined"])
    }

    /// Work nothing will release is reported, not waited on: the drain ends unsettled.
    func testAGroupThatNeverEmptiesLeavesTheDrainUnsettled() async {
        let backlog = WorkBacklog()
        let group = DispatchGroup()
        group.enter()

        backlog.enqueue(on: Queue(), label: "Q", discipline: .main, notifying: group) {}
        let settled = await backlog.drain(recorder: nil)

        XCTAssertFalse(settled)
        XCTAssertEqual(backlog.pendingCount, 1)
        group.leave()
    }

    // MARK: Tasks

    /// An unstructured task spawned through the seam is held like any work, and awaited when it runs:
    /// its whole body, suspensions included, finishes inside the drain.
    func testASpawnedTaskRunsToCompletionInsideTheDrain() async throws {
        let recorder = TraceRecorder(name: "task")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            recorder.call("Prefetcher.prefetch")
            backlog.spawn(on: Queue(), label: "Tasks", discipline: .concurrent) {
                Haruspec.marker("started")
                try? await Task.sleep(nanoseconds: 1_000_000)
                Haruspec.marker("finished")
            }
            recorder.ret("Prefetcher.prefetch")
        }
        await backlog.drain(recorder: recorder)

        XCTAssertEqual(labels(recorder), ["Prefetcher.prefetch", "Prefetcher.prefetch", "started", "finished"])
        let spawn = try XCTUnwrap(events(recorder).first)
        XCTAssertEqual(events(recorder).first { $0.label == "started" }?.spawnedBy, spawn.seq)
        XCTAssertEqual(events(recorder).last?.domain, .queue("Tasks", serial: false))
    }

    /// A task's structured children inherit where the task was handed: they record on its domain.
    func testATasksChildrenRecordOnTheTasksDomain() async {
        let recorder = TraceRecorder(name: "children")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            backlog.spawn(on: Queue(), label: "Tasks", discipline: .concurrent) {
                await withTaskGroup(of: Void.self) { group in
                    for index in 1 ... 3 {
                        group.addTask { Haruspec.marker("child \(index)") }
                    }
                }
            }
        }
        await backlog.drain(recorder: recorder)

        XCTAssertEqual(Set(events(recorder).map(\.domain)), [.queue("Tasks", serial: false)])
        XCTAssertEqual(events(recorder).count, 3)
    }
}
