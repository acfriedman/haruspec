import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
@testable import HaruspecTrace
import XCTest

// Code that waits for its own held work any other way than the capture runs it would hang the capture.
// The watchdog fails it with a message instead. Each test runs one capture with a short stall limit and
// a handler that records the message, then drains the backlog itself to let the stuck operation finish.

// MARK: - Subjects

@Haruspec(schedules: .serial)
protocol CatalogQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

@Haruspec(schedules: .concurrent)
protocol CatalogSpawner: AnyObject {
    func spawn(_ operation: @escaping @Sendable () async -> Void)
}

@Haruspec
protocol Catalog: AnyObject {
    func fetch() async -> Int
    func refresh()
    func load() -> Int
    func prefetch()
}

/// Waits for its own queued work three ways, each fine in production.
final class WaitingCatalog: Catalog, @unchecked Sendable {
    private let queue: any CatalogQueue
    private let spawner: any CatalogSpawner
    private let center: NotificationCenter

    init(queue: any CatalogQueue, spawner: any CatalogSpawner, center: NotificationCenter) {
        self.queue = queue
        self.spawner = spawner
        self.center = center
    }

    /// A spawned task awaiting work queued after it.
    func refresh() {
        spawner.spawn { [self] in
            let count = await fetch()
            center.post(name: .init("CatalogRefreshed"), object: nil, userInfo: ["count": count])
        }
    }

    /// The everyday async bridge over a queue.
    func fetch() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: 42) }
        }
    }

    /// Hands work to the queue and returns, which the capture runs after.
    func prefetch() {
        queue.async { [center] in center.post(name: .init("CatalogPrefetched"), object: nil) }
    }

    /// A semaphore waiting for queued work to signal it.
    func load() -> Int {
        let loaded = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var count = 0
        queue.async {
            count = 42
            loaded.signal()
        }
        loaded.wait()
        return count
    }
}

// MARK: - Tests

final class HeldWorkWaitTests: XCTestCase {
    /// The capture's context, kept so a stall handler can drain its backlog.
    private final class Box: @unchecked Sendable {
        var context: SeamContext?
        var messages: [String] = []
    }

    func testAnOperationAwaitingAContinuationQueuedWorkResumesIsCaught() async throws {
        let messages = await stalls("fetch") { _ = await $0.fetch() }

        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(message.contains("The capture's operation 'fetch' has waited"), message)
        XCTAssertTrue(message.contains("while the capture holds 1 on queue(serial):CatalogQueue"), message)
        XCTAssertTrue(message.contains("withCheckedContinuation"), message)
    }

    func testAHeldTaskAwaitingWorkQueuedAfterItIsCaught() async throws {
        let messages = await stalls("refresh") { $0.refresh() }

        let message = try XCTUnwrap(messages.first)
        XCTAssertTrue(message.contains("The capture's drain after the last operation has waited"), message)
        XCTAssertTrue(message.contains("1 on queue(serial):CatalogQueue"), message)
    }

    func testASemaphoreWaitingOnQueuedWorkIsCaught() async throws {
        let messages = await stalls("load") { _ = $0.load() }

        let message = try XCTUnwrap(messages.first)
        XCTAssertTrue(message.contains("The capture's operation 'load' has waited"), message)
        XCTAssertTrue(message.contains("a semaphore or group wait"), message)
    }

    /// A slow operation is not a stuck one: with no work held, it waits on nothing the capture owns.
    func testASlowOperationHoldingNoWorkIsNeverReported() async {
        let messages = await stalls("slow") { _ in try? await Task.sleep(nanoseconds: 700_000_000) }

        XCTAssertEqual(messages, [])
    }

    /// An operation that keeps recording while work is held is making progress, however long it takes.
    func testAnOperationThatKeepsRecordingIsNeverReported() async {
        let messages = await stalls("busy") { catalog in
            catalog.prefetch()
            for _ in 0 ..< 7 {
                Haruspec.marker("working")
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        XCTAssertEqual(messages, [])
    }

    func testAnOperationThatHandsWorkOffAndReturnsIsNeverReported() async {
        let messages = await stalls("prefetch") { $0.prefetch() }

        XCTAssertEqual(messages, [])
    }

    /// Runs one capture of `operation`, returning each stall message the watchdog reported.
    private func stalls(_ label: String, _ operation: @escaping (any Catalog) async -> Void) async -> [String] {
        let box = Box()
        let spec = Spec<any Catalog>("catalog.waits").operations { Op(label) { await operation($0) } }
        let onStall: @Sendable (String) -> Void = { message in
            box.messages.append(message)
            Task { await box.context?.backlog.drain(recorder: nil) }
        }
        await HeldWorkWatchdog.$stallLimit.withValue(0.3) {
            await HeldWorkWatchdog.$onStall.withValue(onStall) {
                _ = await spec.captured(
                    make: { context in
                        box.context = context
                        return WaitingCatalog(
                            queue: context.double(DoubleCatalogQueue.self),
                            spawner: context.double(DoubleCatalogSpawner.self),
                            center: context.notifications
                        )
                    },
                    order: spec.operations,
                    cassette: Cassette()
                )
            }
        }
        return box.messages
    }
}
