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

    /// A held task that hops to another domain leaves that domain's program order behind, so its first
    /// event there claims the cause again; a later event in the same domain does not.
    func testAHeldTaskClaimsItsCauseAgainInEachDomainItReaches() async throws {
        let recorder = TraceRecorder(name: "hop")
        let backlog = WorkBacklog()

        TraceContext.$current.withValue(recorder) {
            recorder.call("Recommendations.refresh")
            backlog.spawn(on: Queue(), label: "TaskSpawner", discipline: .concurrent) {
                Haruspec.marker("checked")
                await MainActor.run {
                    Haruspec.marker("published")
                    Haruspec.marker("announced")
                }
            }
            recorder.ret("Recommendations.refresh")
        }
        await TraceContext.$capturesOffMain.withValue(true) {
            await backlog.drain(recorder: recorder)
        }

        let refresh = try XCTUnwrap(events(recorder).first { $0.label == "Recommendations.refresh" })
        let byLabel = Dictionary(events(recorder).map { ($0.label, $0) }) { first, _ in first }
        XCTAssertEqual(byLabel["published"]?.domain, .main, "the hop landed on main")
        XCTAssertEqual(byLabel["checked"]?.spawnedBy, refresh.seq)
        XCTAssertEqual(byLabel["published"]?.spawnedBy, refresh.seq, "first on main")
        XCTAssertNil(byLabel["announced"]?.spawnedBy, "main's program order carries the rest")
    }

    /// A call bound for its task still encloses work handed over after an await moved it to main: a
    /// `@MainActor` method runs there while its call was recorded on the capture's thread.
    func testACallStillEnclosesWorkHandedOverAfterAHopToMain() async throws {
        let recorder = TraceRecorder(name: "hop to main")
        let backlog = WorkBacklog()

        await TraceContext.$current.withValue(recorder) {
            let refresh = recorder.call("Shelf.refresh")
            await TraceContext.withOpenCall(refresh) {
                await MainActor.run {
                    backlog.enqueue(on: Queue(), label: "Lookups", discipline: .concurrent) {
                        Haruspec.marker("looked up")
                    }
                }
            }
            recorder.ret("Shelf.refresh")
        }
        await backlog.drain(recorder: recorder)

        let refresh = try XCTUnwrap(events(recorder).first { $0.label == "Shelf.refresh" })
        XCTAssertEqual(events(recorder).first { $0.label == "looked up" }?.spawnedBy, refresh.seq)
    }

    /// Held work a `sync` runs inline inside a traced call was not caused by that call: what it hands on
    /// carries the held work's own cause.
    func testHeldWorkRunInsideASyncHandsOnItsOwnCause() async throws {
        let recorder = TraceRecorder(name: "sync")
        let backlog = WorkBacklog()
        let queue = Queue()

        TraceContext.$current.withValue(recorder) {
            recorder.call("Till.ring")
            backlog.enqueue(on: queue, label: "Till", discipline: .serial) {
                backlog.enqueue(on: queue, label: "Till", discipline: .serial) { Haruspec.marker("posted") }
            }
            recorder.ret("Till.ring")
            recorder.call("Till.readTotal")
            backlog.runSync(on: queue, label: "Till", discipline: .serial) {}
            recorder.ret("Till.readTotal")
        }
        await backlog.drain(recorder: recorder)

        let ring = try XCTUnwrap(events(recorder).first { $0.label == "Till.ring" })
        XCTAssertEqual(events(recorder).first { $0.label == "posted" }?.spawnedBy, ring.seq, "not Till.readTotal")
    }
}
