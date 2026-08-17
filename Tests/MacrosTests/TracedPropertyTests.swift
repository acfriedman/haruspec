@testable import HaruspecCore
import HaruspecMacros
@testable import HaruspecTrace
import XCTest

/// `@Traced` instruments stored `var`s too: each committed write records a `.stateChange` (semantic
/// tier) labeled `"<typeLabel>.<name>"`, carrying the value an observer of the property would read
/// at that moment. Construction records nothing (observers don't fire in `init`), computed
/// properties and `let`s are skipped, and the type declares `FullMutationCapture` — the fact the
/// mutation-order diff needs before it may compare write timelines.
@Traced("Kettle")
final class Kettle {
    var fills = 0
    var litres = 0.0
    let serial = "K-1" // `let`: never written, never stamped
    var summary: String {
        "fills:\(fills)"
    } // computed: no accessor to observe

    func fill(by amount: Double) {
        fills += 1
        litres += amount
    }
}

final class TracedPropertyTests: XCTestCase {
    func testEachCommittedWriteRecordsAStateChange() {
        let recorder = TraceRecorder(name: "t")
        let kettle = Kettle()

        TraceContext.$current.withValue(recorder) { kettle.fill(by: 1.5) }

        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.kind), [.call, .stateChange, .stateChange, .ret])
        XCTAssertEqual(events.map(\.label), ["Kettle.fill", "Kettle.fills", "Kettle.litres", "Kettle.fill"])
        XCTAssertEqual(events[1].payload, .int(1)) // the committed value, read after the write
        XCTAssertEqual(events[2].payload, .double(1.5))
        XCTAssertEqual(events[1].tier, .semantic)
    }

    func testConstructionRecordsNothing() {
        let recorder = TraceRecorder(name: "t")
        TraceContext.$current.withValue(recorder) { _ = Kettle() }
        XCTAssertTrue(recorder.trace().events.isEmpty)
    }

    /// A write that crosses the boundary directly (no enclosing traced call) records too — the
    /// observer sits on the property, not on the methods that happen to reach it.
    func testADirectWriteFromOutsideRecords() {
        let recorder = TraceRecorder(name: "t")
        let kettle = Kettle()

        TraceContext.$current.withValue(recorder) { kettle.fills = 7 }

        XCTAssertEqual(recorder.trace().events.map(\.label), ["Kettle.fills"])
        XCTAssertEqual(recorder.trace().events.first?.payload, .int(7))
    }

    func testInertWithoutActiveCapture() {
        let kettle = Kettle()
        kettle.fill(by: 2) // no recorder bound — must not trap or record
        XCTAssertEqual(kettle.fills, 1)
    }

    func testATracedTypeDeclaresFullMutationCapture() {
        XCTAssertEqual((Kettle() as MutationCapturing).mutationCapture, .full)
    }
}
