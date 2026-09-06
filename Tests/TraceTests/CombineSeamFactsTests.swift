import Combine
import Foundation
@testable import HaruspecTrace
import XCTest

/// The two facts the Combine seam rests on, pinned: the overloads win resolution at the common
/// call shapes, and `debounce` schedules its quiet-period wait through the cancellable `interval`
/// form — the entry point the virtualization must claim.
final class CombineSeamFactsTests: XCTestCase {
    func testSchedulerTakingOperatorsResolveToTheSeam() {
        let received = Just(1).receive(on: DispatchQueue.main)
        let debounced = Just(1).debounce(for: .milliseconds(5), scheduler: DispatchQueue.main)
        let subscribed = Just(1).subscribe(on: DispatchQueue.main)
        let delayed = Just(1).delay(for: .milliseconds(5), scheduler: DispatchQueue.main)
        XCTAssertTrue("\(type(of: received))".contains("TracedScheduler"))
        XCTAssertTrue("\(type(of: debounced))".contains("TracedScheduler"))
        XCTAssertTrue("\(type(of: subscribed))".contains("TracedScheduler"))
        XCTAssertTrue("\(type(of: delayed))".contains("TracedScheduler"))
    }

    /// A same-shape overload would be ambiguous rather than preferred, so `throttle` (which
    /// defaults nothing) deliberately has none — its scheduler stays unwrapped.
    func testThrottleStaysUnclaimed() {
        let throttled = Just(1).throttle(for: .milliseconds(5), scheduler: DispatchQueue.main, latest: true)
        XCTAssertFalse("\(type(of: throttled))".contains("TracedScheduler"))
    }

    struct SpyScheduler: Scheduler {
        typealias SchedulerTimeType = DispatchQueue.SchedulerTimeType
        typealias SchedulerOptions = DispatchQueue.SchedulerOptions
        let calls: NSMutableArray

        var now: SchedulerTimeType {
            DispatchQueue.main.now
        }

        var minimumTolerance: SchedulerTimeType.Stride {
            DispatchQueue.main.minimumTolerance
        }

        func schedule(options _: SchedulerOptions?, _ action: @escaping () -> Void) {
            calls.add("immediate")
            action()
        }

        func schedule(
            after _: SchedulerTimeType,
            tolerance _: SchedulerTimeType.Stride,
            options _: SchedulerOptions?,
            _ action: @escaping () -> Void
        ) {
            calls.add("after")
            action()
        }

        func schedule(
            after _: SchedulerTimeType,
            interval _: SchedulerTimeType.Stride,
            tolerance _: SchedulerTimeType.Stride,
            options _: SchedulerOptions?,
            _ action: @escaping () -> Void
        ) -> Cancellable {
            calls.add("interval")
            action()
            return AnyCancellable {}
        }
    }

    func testDebounceWaitsThroughTheCancellableIntervalForm() {
        let calls = NSMutableArray()
        let cancellable = [1, 2].publisher
            .debounce(for: .milliseconds(5), scheduler: SpyScheduler(calls: calls), options: nil)
            .sink { _ in }
        XCTAssertTrue((calls as? [String] ?? []).contains("interval"), "\(calls)")
        _ = cancellable
    }

    func testReceiveDeliversThroughTheImmediateForm() {
        let calls = NSMutableArray()
        let cancellable = Just(9)
            .receive(on: SpyScheduler(calls: calls), options: nil)
            .sink { _ in }
        XCTAssertTrue((calls as? [String] ?? []).contains("immediate"), "\(calls)")
        _ = cancellable
    }
}
