import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// Main-actor work records `main` wherever it runs inside a capture, even when the frame that records
/// it declares no isolation of its own.
///
/// `#isolation` stops at the recording frame's nonisolated signature, so the thread is the signal. A
/// capture vouches for it (``TraceContext/capturesOffMain``) because its own frames never run on main.
final class MainActorDomainTests: XCTestCase {
    /// Stands in for a scheduling double.
    private final class Queue {}

    /// A spawned task that hops to the main actor records `main` there and the spawner elsewhere: the
    /// recording frame is nonisolated, so only the thread says where the hop landed.
    func testATaskThatHopsToMainRecordsMainWhereItRuns() async {
        let recorder = TraceRecorder(name: "hop")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            backlog.spawn(on: Queue(), label: "Tasks", discipline: .concurrent) {
                recordFromNonisolatedCode("stock check")
                await MainActor.run { recordFromNonisolatedCode("publish") }
            }
        }
        await TraceContext.$capturesOffMain.withValue(true) {
            await backlog.drain(recorder: recorder)
        }

        let byLabel = Dictionary(uniqueKeysWithValues: events(recorder).map { ($0.label, $0.domain) })
        XCTAssertEqual(byLabel["stock check"], .queue("Tasks", serial: false))
        XCTAssertEqual(byLabel["publish"], .main)
    }

    /// Outside a capture that vouches for main, the thread says nothing: the hop reads as the
    /// spawner, as it did before the rung.
    func testTheMainThreadSaysNothingUnlessTheCaptureVouchesForIt() async {
        let recorder = TraceRecorder(name: "unvouched")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            backlog.spawn(on: Queue(), label: "Tasks", discipline: .concurrent) {
                await MainActor.run { recordFromNonisolatedCode("publish") }
            }
        }
        await backlog.drain(recorder: recorder)

        XCTAssertEqual(events(recorder).first?.domain, .queue("Tasks", serial: false))
    }

    /// A block cannot hop, so a `sync` from main-actor code records its queue, as GCD names it.
    @MainActor
    func testASyncFromMainRecordsTheQueue() {
        let recorder = TraceRecorder(name: "sync-from-main")
        let backlog = WorkBacklog()

        TraceContext.$capturesOffMain.withValue(true) {
            TraceContext.$current.withValue(recorder) {
                backlog.runSync(on: Queue(), label: "CartQueue", discipline: .serial) {
                    recordFromNonisolatedCode("read")
                }
            }
        }

        XCTAssertEqual(events(recorder).first?.domain, .queue("CartQueue", serial: true))
    }

    private func events(_ recorder: TraceRecorder) -> [TraceEvent] {
        recorder.trace().events
    }
}

/// Records a marker from a frame that declares no isolation, as a stamped double or the recording
/// notification center does, whatever its caller's isolation.
private func recordFromNonisolatedCode(_ label: String) {
    Haruspec.marker(label)
}
