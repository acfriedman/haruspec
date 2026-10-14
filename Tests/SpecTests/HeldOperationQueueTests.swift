import Combine
import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// A subject that takes an injected `OperationQueue` is checked with `context.operationQueue(_:)`: its
// operations start as held work, and the queue runs each completion block itself, so Foundation never
// delivers one on a thread the capture doesn't hold.

// MARK: - Subjects

/// A photo, by name.
struct Photo: Equatable {
    let name: String
}

/// An operation that uploads one photo.
final class UploadOperation: Operation, @unchecked Sendable {
    let photo: Photo
    private let log: (String) -> Void

    init(_ photo: Photo, log: @escaping (String) -> Void = { _ in }) {
        self.photo = photo
        self.log = log
    }

    override func main() {
        log("upload \(photo.name)")
    }
}

/// An asynchronous operation, as network operations are: it finishes when its response lands on a
/// scheduler, not when `start()` returns.
final class ResponseOperation<S: Scheduler>: Operation, @unchecked Sendable {
    private let scheduler: S
    private let log: (String) -> Void
    private let label: String
    private var running = false
    private var done = false

    init(_ name: String, scheduler: S, log: @escaping (String) -> Void) {
        label = name
        self.scheduler = scheduler
        self.log = log
    }

    override var isAsynchronous: Bool {
        true
    }

    override var isExecuting: Bool {
        running
    }

    override var isFinished: Bool {
        done
    }

    override func start() {
        willChangeValue(forKey: "isExecuting")
        running = true
        didChangeValue(forKey: "isExecuting")
        log("request \(label)")
        scheduler.schedule { [self] in
            log("response \(label)")
            willChangeValue(forKey: "isExecuting")
            willChangeValue(forKey: "isFinished")
            running = false
            done = true
            didChangeValue(forKey: "isExecuting")
            didChangeValue(forKey: "isFinished")
        }
    }
}

// MARK: - Tests

final class HeldOperationQueueTests: XCTestCase {
    private func context() -> SeamContext {
        SeamContext(notifications: NotificationCenter(), cassette: Cassette())
    }

    /// A log the held work appends to, one item at a time.
    private final class Log: @unchecked Sendable {
        private(set) var lines: [String] = []

        func callAsFunction(_ line: String) {
            lines.append(line)
        }
    }

    // MARK: The queue, driven directly

    func testOperationsAreHeldUntilTheCaptureRunsThem() async {
        let context = context()
        let queue = context.operationQueue(.serial("uploads"))
        let log = Log()

        queue.addOperation(UploadOperation(Photo(name: "cat"), log: log.callAsFunction))
        queue.addOperation { log("block") }

        XCTAssertEqual(log.lines, [], "held, not run")
        XCTAssertEqual(queue.operationCount, 2, "both still on the queue")
        let settled = await context.backlog.drain(recorder: nil)

        XCTAssertTrue(settled)
        XCTAssertEqual(log.lines, ["upload cat", "block"])
        XCTAssertEqual(queue.operations, [], "off the queue once finished")
    }

    func testTheQueueRunsEachCompletionItselfInsideTheDrain() async {
        let context = context()
        let queue = context.operationQueue(.serial("uploads"))
        let log = Log()
        let operations = ["cat", "dog"].map { UploadOperation(Photo(name: $0), log: log.callAsFunction) }
        for operation in operations {
            operation.completionBlock = { [unowned queue] in
                log("completed \(operation.photo.name), on queue: \(queue.operations.contains(operation))")
            }
            queue.addOperation(operation)
        }

        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, [
            "upload cat",
            "completed cat, on queue: false",
            "upload dog",
            "completed dog, on queue: false"
        ], "off the queue, then the completion, then the next start: before the drain returns")
        XCTAssertNil(operations[0].completionBlock, "taken, as Foundation clears it once run")
    }

    func testAFinishedOperationLeavesTheQueueBeforeItsCompletionRuns() async {
        let context = context()
        let queue = context.operationQueue(.concurrent("uploads"))
        let log = Log()
        let first = BlockOperation { log("first") }
        first.completionBlock = { log("first completed") }
        let second = BlockOperation { [unowned queue] in log("second sees first: \(queue.operations.contains(first))") }

        queue.addOperation(first)
        queue.addOperation(second)
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, ["first", "second sees first: false", "first completed"])
    }

    func testAnOperationOnTheMainQueueRunsOnTheMainThread() async {
        let context = context()
        let queue = context.operationQueue(.main)
        let log = Log()
        let operation = BlockOperation { log("main: \(Thread.isMainThread)") }
        operation.completionBlock = { log("completion main: \(Thread.isMainThread)") }

        queue.addOperation(operation)
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, ["main: true", "completion main: true"])
        XCTAssertEqual(queue.maxConcurrentOperationCount, 1)
    }

    func testAnAsynchronousOperationHoldsASerialQueueUntilItFinishes() async {
        let context = context()
        let queue = context.operationQueue(.serial("requests"))
        let network = context.scheduler(.serial("network"))
        let log = Log()
        for name in ["a", "b"] {
            let operation = ResponseOperation(name, scheduler: network, log: log.callAsFunction)
            operation.completionBlock = { log("completed \(name)") }
            queue.addOperation(operation)
        }

        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, [
            "request a",
            "response a",
            "completed a",
            "request b",
            "response b",
            "completed b"
        ])
    }

    func testAConcurrentQueueStartsWhatItHasRoomFor() async {
        let context = context()
        let queue = context.operationQueue(.concurrent("requests"))
        let network = context.scheduler(.serial("network"))
        let log = Log()
        queue.maxConcurrentOperationCount = 2
        for name in ["a", "b", "c"] {
            queue.addOperation(ResponseOperation(name, scheduler: network, log: log.callAsFunction))
        }

        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, [
            "request a",
            "request b",
            "response a",
            "response b",
            "request c",
            "response c"
        ], "two in flight; the third starts once one completes")
    }

    func testAnOperationWaitsForItsDependencies() async {
        let context = context()
        let queue = context.operationQueue(.concurrent("work"))
        let log = Log()
        let first = BlockOperation { log("first") }
        let second = BlockOperation { log("second") }
        second.addDependency(first)

        queue.addOperation(second)
        queue.addOperation(first)
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, ["first", "second"])
    }

    func testADependencyOnAnotherQueueReleasesTheOperationWhenItFinishes() async {
        let context = context()
        let downloads = context.operationQueue(.serial("downloads"))
        let thumbnails = context.operationQueue(.serial("thumbnails"))
        let log = Log()
        let download = BlockOperation { log("download") }
        let thumbnail = BlockOperation { log("thumbnail") }
        thumbnail.addDependency(download)

        thumbnails.addOperation(thumbnail)
        downloads.addOperation(download)
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, ["download", "thumbnail"])
    }

    func testACancelledOperationSkipsMainButStillCompletes() async {
        let context = context()
        let queue = context.operationQueue(.serial("uploads"))
        let log = Log()
        let blocked = BlockOperation { log("blocked ran") }
        blocked.addDependency(BlockOperation {})
        blocked.completionBlock = { log("blocked completed, cancelled: \(blocked.isCancelled)") }

        queue.addOperation(blocked)
        blocked.cancel()
        XCTAssertEqual(queue.operations, [blocked], "still queued until the capture runs it")
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, ["blocked completed, cancelled: true"], "cancelling made it ready")
        XCTAssertEqual(queue.operations, [])
    }

    func testCancelAllOperationsCancelsWhatIsQueued() async {
        let context = context()
        let queue = context.operationQueue(.serial("uploads"))
        let log = Log()
        for name in ["cat", "dog"] {
            let operation = UploadOperation(Photo(name: name), log: log.callAsFunction)
            operation.completionBlock = { log("completed \(name)") }
            queue.addOperation(operation)
        }

        queue.cancelAllOperations()
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, ["completed cat", "completed dog"])
    }

    func testAReadyOperationOfHigherPriorityStartsFirst() async {
        let context = context()
        let queue = context.operationQueue(.serial("work"))
        let log = Log()
        let gate = BlockOperation { log("gate") }
        let low = BlockOperation { log("low") }
        let high = BlockOperation { log("high") }
        low.queuePriority = .low
        high.queuePriority = .high

        queue.addOperation(gate)
        queue.addOperation(low)
        queue.addOperation(high)
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, ["gate", "high", "low"], "the gate started at its add; then by priority")
    }

    func testABarrierWaitsForWhatIsAheadAndHoldsWhatIsBehind() async {
        let context = context()
        let queue = context.operationQueue(.concurrent("work"))
        let network = context.scheduler(.serial("network"))
        let log = Log()

        queue.addOperation(ResponseOperation("a", scheduler: network, log: log.callAsFunction))
        queue.addBarrierBlock { log("barrier") }
        queue.addOperation { log("after") }
        await context.backlog.drain(recorder: nil)

        XCTAssertEqual(log.lines, ["request a", "response a", "barrier", "after"])
    }

    func testASuspendedQueueStartsNothingUntilResumed() async {
        let context = context()
        let queue = context.operationQueue(.serial("uploads"))
        let log = Log()

        queue.isSuspended = true
        queue.addOperation { log("ran") }
        await context.backlog.drain(recorder: nil)
        XCTAssertEqual(log.lines, [])
        XCTAssertEqual(queue.operationCount, 1)

        queue.isSuspended = false
        await context.backlog.drain(recorder: nil)
        XCTAssertEqual(log.lines, ["ran"])
    }

    func testTheDomainFollowsTheConcurrencyTheSubjectSets() async {
        let context = context()
        let recorder = TraceRecorder(name: "domains")
        let queue = context.operationQueue(.concurrent("uploads"))
        let center = RecordingNotificationCenter()
        let post: @Sendable () -> Void = { center.post(name: .init("Ran"), object: nil) }

        queue.addOperation(post)
        await context.backlog.drain(recorder: recorder)
        queue.maxConcurrentOperationCount = 1
        queue.addOperation(post)
        await context.backlog.drain(recorder: recorder)

        let domains = recorder.trace().events.map(\.domain.description)
        XCTAssertEqual(domains, ["queue(concurrent):uploads", "queue(serial):uploads"])
    }
}
