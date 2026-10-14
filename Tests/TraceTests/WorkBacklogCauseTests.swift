import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// Held work's happens-before cause across hops. The first held item names the traced call that
/// enqueued it; what it hands on, with no call open, carries that cause forward.
final class WorkBacklogCauseTests: XCTestCase {
    /// Stands in for a scheduling double: the identity `sync` drains by.
    private final class Queue {}

    private func events(_ recorder: TraceRecorder) -> [TraceEvent] {
        recorder.trace().events
    }

    /// Work held from inside held work, with no traced call open, carries that work's cause forward:
    /// the call that caused the first item caused everything it handed on, however many hops away.
    func testWorkHandedOnFromHeldWorkNamesTheOriginalCall() async throws {
        let recorder = TraceRecorder(name: "hops")
        let backlog = WorkBacklog()
        let queue = Queue()

        TraceContext.$current.withValue(recorder) {
            recorder.call("Uploader.upload")
            backlog.enqueue(on: queue, label: "Uploads", discipline: .serial) {
                Haruspec.marker("sent")
                backlog.enqueue(on: queue, label: "Uploads", discipline: .serial) {
                    backlog.enqueue(on: queue, label: "Uploads", discipline: .serial) {
                        Haruspec.marker("confirmed")
                    }
                }
            }
            recorder.ret("Uploader.upload")
        }
        await backlog.drain(recorder: recorder)

        let upload = try XCTUnwrap(events(recorder).first { $0.label == "Uploader.upload" })
        XCTAssertEqual(events(recorder).first { $0.label == "sent" }?.spawnedBy, upload.seq)
        XCTAssertEqual(
            events(recorder).first { $0.label == "confirmed" }?.spawnedBy,
            upload.seq,
            "three hops on, through an item that recorded nothing"
        )
    }

    /// A traced call open inside held work is the nearer cause, so it wins over the one carried forward.
    func testACallOpenInsideHeldWorkIsTheCauseOfWhatItHandsOn() async throws {
        let recorder = TraceRecorder(name: "nearer")
        let backlog = WorkBacklog()
        let queue = Queue()

        TraceContext.$current.withValue(recorder) {
            recorder.call("Uploader.upload")
            backlog.enqueue(on: queue, label: "Uploads", discipline: .serial) {
                recorder.call("Ledger.record")
                backlog.enqueue(on: queue, label: "Uploads", discipline: .serial) { Haruspec.marker("recorded") }
                recorder.ret("Ledger.record")
            }
            recorder.ret("Uploader.upload")
        }
        await backlog.drain(recorder: recorder)

        let record = try XCTUnwrap(events(recorder).first { $0.label == "Ledger.record" })
        XCTAssertEqual(events(recorder).first { $0.label == "recorded" }?.spawnedBy, record.seq)
    }

    /// A cause read earlier is the one the work carries, whatever is open when it is finally held.
    func testACauseReadEarlierIsTheOneTheWorkCarries() async throws {
        let recorder = TraceRecorder(name: "deferred")
        let backlog = WorkBacklog()
        nonisolated(unsafe) var cause: WorkBacklog.Cause?

        TraceContext.$current.withValue(recorder) {
            recorder.call("Uploader.upload")
            cause = WorkBacklog.causeHere()
            recorder.ret("Uploader.upload")
            recorder.call("Uploader.cancel")
            backlog.enqueue(on: Queue(), label: "Uploads", discipline: .serial, causedBy: cause) {
                Haruspec.marker("started")
            }
            recorder.ret("Uploader.cancel")
        }
        await backlog.drain(recorder: recorder)

        let upload = try XCTUnwrap(events(recorder).first { $0.label == "Uploader.upload" })
        XCTAssertEqual(events(recorder).first { $0.label == "started" }?.spawnedBy, upload.seq)
    }
}
