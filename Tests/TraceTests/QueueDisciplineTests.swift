import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// Where a domain's ordering discipline comes from — captured at the sites that *know* it, never
/// guessed at diff time. An injected `RecordingOperationQueue` reads its own width at the enqueue;
/// a queue's creation seam registers the discipline its attributes stated.
final class QueueDisciplineTests: XCTestCase {
    private func recordedDomain(width: Int) async -> ConcurrencyDomain? {
        let recorder = TraceRecorder(name: "discipline")
        let queue = RecordingOperationQueue()
        queue.maxConcurrentOperationCount = width
        queue.name = "com.emporium.discipline-\(width)"

        TraceContext.$current.withValue(recorder) {
            queue.addOperation { Haruspec.marker("on-queue") }
        }
        await DispatchSeam.quiesce()
        return recorder.trace().events.first?.domain
    }

    /// `maxConcurrentOperationCount == 1` is the operation-queue spelling of "serial", and it is the
    /// queue object itself that answers — no registry involved.
    func testAWidthOneOperationQueueIsSerial() async {
        let domain = await recordedDomain(width: 1)
        if case let .queue(_, serial) = domain {
            XCTAssertTrue(serial)
        } else {
            XCTFail("expected a queue domain, got \(String(describing: domain))")
        }
    }

    func testAWiderOperationQueueIsConcurrent() async {
        let domain = await recordedDomain(width: 2)
        if case let .queue(_, serial) = domain {
            XCTAssertFalse(serial)
        } else {
            XCTFail("expected a queue domain, got \(String(describing: domain))")
        }
    }

    /// The registry answers for work that arrives with no discipline mark of its own — the
    /// `dispatch_sync` path, where the seam never wrapped an enqueue.
    func testTheCreationRegistryAnswersForUnmarkedWork() {
        let recorder = TraceRecorder(name: "discipline")
        let concurrent = DispatchQueue(label: "com.emporium.registry-concurrent", attributes: .concurrent)

        concurrent.sync { recorder.marker("via-sync") }

        XCTAssertEqual(
            recorder.trace().events.first?.domain,
            .queue("com.emporium.registry-concurrent", serial: false)
        )
    }

    /// A queue whose creation nobody saw defaults to serial: the strict reading, under which its
    /// order stays a checked contract rather than silently becoming noise.
    func testAnUnregisteredQueueDefaultsToSerial() {
        let recorder = TraceRecorder(name: "discipline")
        let unseen = DispatchQueue(
            label: "com.emporium.unregistered",
            qos: .unspecified,
            attributes: .concurrent,
            autoreleaseFrequency: .inherit,
            target: nil
        ) // the fully-specified initializer — the one shape no seam overload claims

        unseen.sync { recorder.marker("via-sync") }

        XCTAssertEqual(
            recorder.trace().events.first?.domain,
            .queue("com.emporium.unregistered", serial: true)
        )
    }
}
