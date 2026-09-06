import Combine
import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
@testable import HaruspecTrace
import XCTest

// The Combine scheduling seam, end to end: the overloads claim `debounce`/`receive(on:)` by
// preference, the wrapped scheduler virtualizes the debounce timer, and the capture's drain loop
// fires it at quiescence — so the pipeline's settled state is inside the window and a dead
// pipeline is distinguishable from a live one. Outside a capture the wrapped scheduler is a
// verbatim pass-through, asserted on the wall clock.

protocol Dial: AnyObject {
    var setting: Int { get set }
    var echoed: Int { get }
}

/// The textbook deferred pipeline: debounce on main, hop to main, echo into an output property.
private final class DebouncedDial: Dial {
    @Published var setting = 0
    @Published private(set) var echoed = -1
    private var cancellables = Set<AnyCancellable>()

    init() {
        $setting
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.echoed = value }
            .store(in: &cancellables)
    }
}

/// The dead pipeline: same surface, nothing wired. Before the seam these two were
/// indistinguishable — every emission lived past the window.
private final class DeadDial: Dial {
    var setting = 0
    private(set) var echoed = -1
}

final class CombineSeamTests: XCTestCase {
    private func dial(system: @escaping (SeamContext) -> Dial) -> Spec<Dial> {
        Spec<Dial>("dial.combineseam")
            .system(system)
            .operations {
                Op("setting", varying: .oneOf(1, 2, 3)) { $0.setting = $1 }
            }
            .observes(Observed("Dial.echoed") { $0.echoed })
    }

    /// The pipeline settles deterministically at quiescence on both sides — virtual firing is not
    /// a race, so the self-check is equivalent, with the echoed value observed rather than `-1`.
    func testTheLivePipelineIsEquivalentToItself() async {
        let verdict = await dial { _ in DebouncedDial() }.verify(against: { _ in DebouncedDial() })
        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    /// The seam's whole point: a pipeline that never delivers now reads DIVERGED on the settled
    /// snapshot, where it used to read equivalent because neither side delivered in-window.
    func testADeadPipelineDivergesOnTheSettledSnapshot() async {
        let verdict = await dial { _ in DebouncedDial() }.verify(against: { _ in DeadDial() })
        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(verdict.report().contains("Dial.echoed"), verdict.report())
    }

    /// Outside a capture the wrapped scheduler forwards verbatim: the debounce fires on the wall
    /// clock and production behavior is untouched.
    func testOutsideACaptureTheTimerFiresForReal() {
        let dial = DebouncedDial()
        dial.setting = 7
        let settled = expectation(description: "debounce fired on the wall clock")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if dial.echoed == 7 {
                settled.fulfill()
            }
        }
        wait(for: [settled], timeout: 2)
    }

    /// Timers are keyed by capture: one recorder's quiescence cannot fire another's.
    func testDeferredTimersAreScopedToTheirCapture() {
        let mine = TraceRecorder(name: "mine", clock: ManualClock())
        let theirs = TraceRecorder(name: "theirs", clock: ManualClock())
        var fired = false
        DeferredTimers.hold(for: mine) { fired = true }
        XCTAssertFalse(DeferredTimers.fire(for: theirs))
        XCTAssertFalse(fired)
        XCTAssertTrue(DeferredTimers.fire(for: mine))
        XCTAssertTrue(fired)
    }
}
