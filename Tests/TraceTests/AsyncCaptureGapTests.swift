import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import LegacyObjC
import XCTest

/// Capture across GCD hops, pinned against genuine Obj-C (`LegacyObjC/LegacyCatalogClient.m`, the same
/// callback-pyramid shape as the dogfood app's `APIClient`). That fixture is compiled through the
/// **preprocessing seam** (`Sources/DispatchSeam/haruspec_dispatch.h`), so these exercise the seam end
/// to end rather than the shim in isolation.
///
/// Two problems the seam closes, both by wrapping the *enqueue* rather than the execution — the
/// enqueue site being the only place either fact is still known:
///
/// - **Reachability.** A GCD block runs on a thread with no Swift task, so a task-local recorder is
///   unreachable from inside it. The seam captures the ambient recorder at enqueue and rebinds it
///   around the block, which is causal inheritance: work not descended from a traced call is still
///   never captured.
/// - **Quiescence.** A trace read when the capture window closes races work the window kicked off.
///   The seam counts wrapped blocks out and back in, so `DispatchSeam.quiesce()` is exact rather than a
///   guess about queues going idle.
final class AsyncCaptureGapTests: XCTestCase {
    private func labels(_ recorder: TraceRecorder) -> [String] {
        recorder.trace().events.map(\.label)
    }

    // MARK: - Reachability

    /// The callback pyramid, whole: work on the background queue, and the completion delivered back to
    /// main, both recorded — and each carrying the domain it actually ran on.
    func testWorkOnAGCDQueueIsRecorded() {
        let recorder = TraceRecorder(name: "pyramid")
        let client = LegacyCatalogClient()
        let delivered = expectation(description: "completion")

        TraceContext.$current.withValue(recorder) {
            Haruspec.marker("before-fetch")
            client.fetchProducts(notifier: {
                Haruspec.marker("on-background-queue")
            }, completion: { _ in
                Haruspec.marker("in-completion")
                delivered.fulfill()
            })
            wait(for: [delivered], timeout: 5)
            Haruspec.marker("after-fetch")
        }

        XCTAssertEqual(
            labels(recorder),
            ["before-fetch", "on-background-queue", "in-completion", "after-fetch"]
        )
        let byLabel = Dictionary(uniqueKeysWithValues: recorder.trace().events.map { ($0.label, $0.domain) })
        XCTAssertEqual(byLabel["on-background-queue"], .queue("com.emporium.catalog"))
        // The test body declares no isolation, so the caller-side marker is ambient — where the
        // harness runs is not a fact about the subject.
        XCTAssertEqual(byLabel["before-fetch"], .ambient)
    }

    /// A traced call and a notification posted from the *same* block now agree. Before the seam the
    /// notification landed and the traced call did not — the interceptor holds the recorder directly
    /// while `@Traced` looks it up — so a trace could show an effect with none of the work behind it.
    func testTracedCallAndNotificationFromOneBlockAgree() {
        let recorder = TraceRecorder(name: "agree")
        let center = NotificationCenter()
        let interceptor = NotificationInterceptor(recorder: recorder, center: center)
        interceptor.start(); defer { interceptor.stop() }

        let client = LegacyCatalogClient()
        let delivered = expectation(description: "completion")
        TraceContext.$current.withValue(recorder) {
            client.fetchProducts(notifier: {
                Haruspec.marker("traced-call-on-queue")
                center.post(name: Notification.Name("CatalogDidLoad"), object: nil)
            }, completion: { _ in delivered.fulfill() })
            wait(for: [delivered], timeout: 5)
        }

        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.label), ["traced-call-on-queue", "CatalogDidLoad"])
        XCTAssertEqual(Set(events.map(\.domain)), [.queue("com.emporium.catalog")])
    }

    /// Work no caller can await is still captured — the seam does not need a completion handler to
    /// exist, only an enqueue to pass through.
    func testFireAndForgetWorkIsRecorded() async {
        let recorder = TraceRecorder(name: "warm")
        let client = LegacyCatalogClient()
        client.cacheWarmedHandler = { Haruspec.marker("cache-warmed") }

        TraceContext.$current.withValue(recorder) {
            Haruspec.marker("before-warm")
            client.warmCache()
        }
        // Quiesce *after* the window, not inside it: the seam captured the recorder at enqueue, so
        // draining does not depend on the window still being open — and a run loop cannot be pumped
        // inside a synchronous task-local binding under actor isolation without violating its
        // stack discipline.
        let drained = await DispatchSeam.quiesce(timeout: 5)
        XCTAssertTrue(drained)

        XCTAssertEqual(labels(recorder), ["before-warm", "cache-warmed"])
    }

    /// Nothing is captured when no capture is active: the shim returns the block untouched and the
    /// enqueue is not counted. Production behaviour, and the property that makes the seam safe to leave
    /// compiled in.
    func testSeamIsAPassThroughOutsideACaptureWindow() {
        let client = LegacyCatalogClient()
        let warmed = expectation(description: "warmed")
        client.cacheWarmedHandler = { warmed.fulfill() }

        client.warmCache()
        wait(for: [warmed], timeout: 5)
        XCTAssertEqual(DispatchSeam.outstanding, 0)
    }

    // MARK: - Quiescence

    /// `quiesce()` is exact, not a sleep: it returns once every block the seam handed out has finished,
    /// so the snapshot stops depending on when it was taken. Repeated, because the property being
    /// asserted is the absence of a race.
    func testQuiesceWaitsForOutstandingWork() async {
        for _ in 1 ... 20 {
            let recorder = TraceRecorder(name: "quiesce")
            let client = LegacyCatalogClient()
            client.cacheWarmedHandler = { Haruspec.marker("cache-warmed") }

            TraceContext.$current.withValue(recorder) {
                client.warmCache()
            }
            let drained = await DispatchSeam.quiesce(timeout: 5)
            XCTAssertTrue(drained)
            XCTAssertEqual(labels(recorder), ["cache-warmed"])
            XCTAssertEqual(DispatchSeam.outstanding, 0)
        }
    }

    /// Quiescing from the main actor must not deadlock against work hopping *back* to main — the
    /// callback pyramid's second leg. Awaiting frees the thread so that leg can run.
    ///
    /// The blocks are `@Sendable` deliberately: closures written inside a `@MainActor` member inherit
    /// its isolation, and handing one to GCD to run elsewhere is what Swift 6 traps on. That is the
    /// migration bug this whole effort is about — worth reproducing correctly rather than by accident.
    @MainActor
    func testQuiesceFromTheMainThreadDoesNotDeadlock() async {
        let recorder = TraceRecorder(name: "pyramid-quiesce")
        let client = LegacyCatalogClient()

        TraceContext.$current.withValue(recorder) {
            client.fetchProducts(notifier: { @Sendable in
                Haruspec.marker("on-background-queue")
            }, completion: { @Sendable _ in
                Haruspec.marker("in-completion")
            })
        }
        let drained = await DispatchSeam.quiesce(timeout: 5)
        XCTAssertTrue(drained)

        // Quiesce returning is itself the assertion that the completion ran: it is counted work.
        XCTAssertEqual(labels(recorder), ["on-background-queue", "in-completion"])
    }

    /// The last hole the seam closes. An unawaited `Task` inherits the recorder, so it was always
    /// *captured* — nothing marked it outstanding, so whether it beat the snapshot was a race. That
    /// measured 0–2 of 20 in isolation, and across a spec's thousand-odd probes became a near-certain
    /// red attributable to nothing.
    ///
    /// A task whose value is awaited was never the problem: awaiting it *is* quiescence. Fire-and-forget
    /// is, and fire-and-forget is `Success == Void` — which is exactly what the overload claims.
    func testUnawaitedTaskIsCountedAndDrains() async {
        for _ in 1 ... 20 {
            let recorder = TraceRecorder(name: "deferred")
            TraceContext.$current.withValue(recorder) {
                Task { Haruspec.marker("deferred-work") }
            }
            let drained = await DispatchSeam.quiesce(timeout: 5)
            XCTAssertTrue(drained)
            XCTAssertEqual(labels(recorder), ["deferred-work"])
            XCTAssertEqual(DispatchSeam.outstanding, 0)
        }
    }

    /// `Task.detached` inherits nothing, so it needed the wrapper for reachability as well as counting.
    func testDetachedTaskIsReachedAndCounted() async {
        let recorder = TraceRecorder(name: "detached")
        TraceContext.$current.withValue(recorder) {
            Task.detached { Haruspec.marker("detached-work") }
        }
        let drained = await DispatchSeam.quiesce(timeout: 5)
        XCTAssertTrue(drained)
        XCTAssertEqual(labels(recorder), ["detached-work"])
    }
}
