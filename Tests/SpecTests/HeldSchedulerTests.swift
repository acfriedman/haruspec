import Combine
import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// A subject that takes an injected Combine `Scheduler` is checked with `context.scheduler(_:)`: its
// work is held like a stamped scheduling double's, and its clock is the capture's virtual time, so a
// pipeline that delays, debounces or measures reads the same on every run.

// MARK: - Subjects

/// Uploads, then tells observers on its scheduler.
@Haruspec
protocol Uploading: AnyObject {
    func upload(_ name: String)
}

/// Hops to its scheduler before posting.
final class Uploader<S: Scheduler>: Uploading {
    private let scheduler: S
    private let center: NotificationCenter

    init(scheduler: S, center: NotificationCenter) {
        self.scheduler = scheduler
        self.center = center
    }

    func upload(_ name: String) {
        scheduler.schedule { [center] in
            center.post(name: .init("UploadFinished"), object: nil, userInfo: ["name": name])
        }
    }
}

/// A port that drops the hop and posts on the caller's thread.
final class UnhoppedUploader: Uploading {
    private let center: NotificationCenter

    init(center: NotificationCenter) {
        self.center = center
    }

    func upload(_ name: String) {
        center.post(name: .init("UploadFinished"), object: nil, userInfo: ["name": name])
    }
}

/// Searches once typing has settled.
@Haruspec
protocol Searching: AnyObject {
    func search(_ query: String)
}

/// Debounces the query on its scheduler and announces each search.
final class DebouncedSearch<S: Scheduler>: Searching where S.SchedulerTimeType == DispatchQueue.SchedulerTimeType {
    private let queries = PassthroughSubject<String, Never>()
    private var subscription: AnyCancellable?

    init(scheduler: S, center: NotificationCenter, settle: S.SchedulerTimeType.Stride = .milliseconds(300)) {
        subscription = queries
            .debounce(for: settle, scheduler: scheduler)
            .sink { center.post(name: .init("SearchFired"), object: nil, userInfo: ["query": $0]) }
    }

    func search(_ query: String) {
        queries.send(query)
    }
}

/// Measures how long each delayed ping took to land.
@Haruspec
protocol Pinging: AnyObject {
    func ping()
}

/// Delays each ping, then reports the interval since the last one landed.
final class MeasuredPinger<S: Scheduler>: Pinging where S.SchedulerTimeType == DispatchQueue.SchedulerTimeType {
    private let pings = PassthroughSubject<Void, Never>()
    private var subscription: AnyCancellable?

    init(scheduler: S, center: NotificationCenter) {
        subscription = pings
            .delay(for: .milliseconds(300), scheduler: scheduler)
            .measureInterval(using: scheduler)
            .sink { center.post(name: .init("Pinged"), object: nil, userInfo: ["ns": $0.magnitude]) }
    }

    func ping() {
        pings.send()
    }
}

// MARK: - Tests

final class HeldSchedulerTests: XCTestCase {
    private func context() -> SeamContext {
        SeamContext(notifications: NotificationCenter(), cassette: Cassette())
    }

    // MARK: The scheduler, driven directly

    func testTheImmediateFormIsHeldUntilTheCaptureRunsIt() async {
        let context = context()
        let scheduler = context.scheduler(.main)
        nonisolated(unsafe) var ran: [Bool] = []

        scheduler.schedule { ran.append(Thread.isMainThread) }

        XCTAssertEqual(ran, [], "held, not run")
        await context.backlog.drain(recorder: nil)
        XCTAssertEqual(ran, [true], "run once the capture drains, on the main thread")
    }

    func testNowIsVirtualAndDelayedWorkFiresInDeadlineOrder() async {
        let context = context()
        let scheduler = context.scheduler(.serial("timers"))
        let start = scheduler.now
        nonisolated(unsafe) var fired: [(String, Int)] = []

        scheduler.schedule(after: start.advanced(by: .milliseconds(200))) {
            fired.append(("late", start.distance(to: scheduler.now).magnitude))
        }
        scheduler.schedule(after: start.advanced(by: .milliseconds(100))) {
            fired.append(("early", start.distance(to: scheduler.now).magnitude))
        }
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(fired.map(\.0), ["early", "late"])
        XCTAssertEqual(fired.map(\.1), [100_000_000, 200_000_000], "now is each deadline, exactly")
        XCTAssertEqual(scheduler.now, start.advanced(by: .milliseconds(200)))
    }

    func testNowReadsTheSameInstantInEveryCapture() {
        XCTAssertEqual(context().scheduler(.main).now, context().scheduler(.serial("other")).now)
    }

    func testATimeAlreadyPastIsDueAtOnce() async {
        let context = context()
        let scheduler = context.scheduler(.main)
        nonisolated(unsafe) var fired = false

        scheduler.schedule(after: scheduler.now.advanced(by: .seconds(-5))) { fired = true }
        await context.backlog.drain(recorder: nil)

        XCTAssertTrue(fired)
        XCTAssertEqual(context.backlog.virtualTime, 0, "the clock does not run backwards")
    }

    func testTheRepeatingFormRearmsUntilCancelled() async {
        let context = context()
        let scheduler = context.scheduler(.serial("ticker"))
        let start = scheduler.now
        nonisolated(unsafe) var ticks: [Int] = []
        nonisolated(unsafe) var repetition: Cancellable?

        repetition = scheduler.schedule(after: start.advanced(by: .milliseconds(50)), interval: .milliseconds(100)) {
            ticks.append(start.distance(to: scheduler.now).magnitude / 1_000_000)
            if ticks.count == 3 {
                repetition?.cancel()
            }
        }
        let settled = await context.backlog.drain(recorder: nil)

        XCTAssertEqual(ticks, [50, 150, 250], "first at the date, then every interval")
        XCTAssertTrue(settled, "a cancelled repetition leaves nothing held")
    }

    /// A schedule its own action cancels records no fire after that one: `debounce` cancels its
    /// repeating schedule once it emits, and a dead fire would be a `timer` no queue makes.
    func testARepetitionItsActionCancelsRecordsNoFurtherTimer() async {
        let context = context()
        let recorder = TraceRecorder(name: "repetition")
        let scheduler = context.scheduler(.main)
        nonisolated(unsafe) var repetition: Cancellable?

        repetition = scheduler.schedule(after: scheduler.now, interval: .milliseconds(100)) {
            repetition?.cancel()
        }
        await context.backlog.drain(recorder: recorder)

        XCTAssertEqual(recorder.trace().events.filter { $0.kind == .timer }.count, 1)
    }

    func testADebounceRecordsOneTimerPerValueItWaitsOn() async {
        let context = context()
        let recorder = TraceRecorder(name: "debounce")
        let values = PassthroughSubject<Int, Never>()
        nonisolated(unsafe) var emitted: [Int] = []
        let subscription = values
            .debounce(for: .milliseconds(300), scheduler: context.scheduler(.main))
            .sink { emitted.append($0) }

        values.send(1)
        await context.backlog.drain(recorder: recorder)
        values.send(2)
        await context.backlog.drain(recorder: recorder)

        XCTAssertEqual(emitted, [1, 2])
        XCTAssertEqual(recorder.trace().events.filter { $0.kind == .timer }.count, 2)
        subscription.cancel()
    }

    func testARepetitionCancelledBeforeItsFirstFireNeverRuns() async {
        let context = context()
        let scheduler = context.scheduler(.main)
        nonisolated(unsafe) var fired = false

        let repetition = scheduler.schedule(after: scheduler.now, interval: .seconds(1)) { fired = true }
        repetition.cancel()
        await context.backlog.drain(recorder: nil)

        XCTAssertFalse(fired)
    }

    func testARepetitionNeverCancelledStopsAtTheStepLimit() async {
        let context = context()
        let scheduler = context.scheduler(.serial("forever"))
        nonisolated(unsafe) var ticks = 0

        let repetition = scheduler.schedule(after: scheduler.now, interval: .milliseconds(10)) { ticks += 1 }
        let settled = await context.backlog.drain(recorder: nil)

        XCTAssertFalse(settled, "the drain reports work still held")
        XCTAssertEqual(ticks, WorkBacklog.stepLimit)
        repetition.cancel()
    }

    func testTheImmediateFormKeepsItsWorkInItsGroupUntilItRuns() async {
        let context = context()
        let scheduler = context.scheduler(.main)
        let group = DispatchGroup()

        scheduler.schedule(options: .init(group: group)) {}

        XCTAssertEqual(group.wait(timeout: .now()), .timedOut, "in the group while held")
        await context.backlog.drain(recorder: nil)
        XCTAssertEqual(group.wait(timeout: .now()), .success, "out of it once run")
    }

    func testItStandsInForADispatchQueueScheduler() {
        /// `AnySchedulerOf<DispatchQueue>`, and any scheduler generic over these types, takes it.
        func takesDispatchQueueScheduler<S: Scheduler>(_: S) -> Bool
            where S.SchedulerTimeType == DispatchQueue.SchedulerTimeType,
            S.SchedulerOptions == DispatchQueue.SchedulerOptions {
            true
        }

        XCTAssertTrue(takesDispatchQueueScheduler(context().scheduler(.main)))
    }

    // MARK: A subject checked through it

    func testAHopToTheSchedulerIsEquivalentToItself() async {
        let verdict = await uploading
            .verify { context in Uploader(scheduler: context.scheduler(.main), center: context.notifications) }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testADroppedHopDiverges() async {
        let verdict = await uploading.verify { context in UnhoppedUploader(center: context.notifications) }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(verdict.report().contains("ran on a different domain"), verdict.report())
    }

    func testAHopToAnotherQueueDiverges() async {
        let verdict = await uploading.verify { context in
            Uploader(scheduler: context.scheduler(.serial("uploads")), center: context.notifications)
        }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(verdict.report().contains("queue(serial):uploads"), verdict.report())
    }

    private var uploading: BaselinedSpec<any Uploading> {
        Spec<any Uploading>("uploading.scheduler")
            .operations { Op("upload") { $0.upload("cat.jpg") } }
            .baselined { context in Uploader(scheduler: context.scheduler(.main), center: context.notifications) }
    }

    func testADebounceIsEquivalentToItself() async {
        let verdict = await searching.verify { context in
            DebouncedSearch(scheduler: context.scheduler(.main), center: context.notifications)
        }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testARetimedDebounceDivergesOnItsTimer() async {
        let verdict = await searching.verify { context in
            DebouncedSearch(
                scheduler: context.scheduler(.main),
                center: context.notifications,
                settle: .milliseconds(200)
            )
        }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(verdict.report().contains("baseline=300 candidate=200"), verdict.report())
    }

    private var searching: BaselinedSpec<any Searching> {
        Spec<any Searching>("searching.debounce")
            .operations {
                Op("typeC") { $0.search("c") }
                Op("typeCa") { $0.search("ca") }
                Op("typeCat") { $0.search("cat") }
            }
            .vary { Ordering(max: 6) }
            .baselined { context in
                DebouncedSearch(scheduler: context.scheduler(.main), center: context.notifications)
            }
    }

    func testAMeasuredIntervalReadsVirtualTimeOnEveryRun() async {
        let verdict = await Spec<any Pinging>("pinging.measured")
            .operations { Op("ping") { $0.ping() } }
            .vary { Ordering(max: 3) }
            .baselined { context in MeasuredPinger(scheduler: context.scheduler(.main), center: context.notifications) }
            .verify { context in MeasuredPinger(scheduler: context.scheduler(.main), center: context.notifications) }

        XCTAssertEqual(verdict.verdict, .equivalent, "a wall clock made this UNSTABLE\n\(verdict.report())")
    }

    func testAMeasuredIntervalIsTheVirtualDelay() async {
        let context = context()
        let center = NotificationCenter()
        nonisolated(unsafe) var measured: [Int] = []
        let observer = center.addObserver(forName: .init("Pinged"), object: nil, queue: nil) {
            measured.append($0.userInfo?["ns"] as? Int ?? -1)
        }
        defer { center.removeObserver(observer) }
        let pinger = MeasuredPinger(scheduler: context.scheduler(.main), center: center)

        pinger.ping()
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(measured, [300_000_000], "the delay, to the nanosecond")
    }
}
