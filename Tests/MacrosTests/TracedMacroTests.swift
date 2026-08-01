@testable import HaruspecCore
import HaruspecMacros
@testable import HaruspecTrace
import XCTest

/// A class instrumented purely by the attribute — no recorder property, no per-method code.
@Traced("Calc")
private final class Calc {
    func add(_ lhs: Int, _ rhs: Int) -> Int {
        lhs + rhs
    }

    func noop() {}
    func mayThrow(_ fail: Bool) throws -> String {
        if fail {
            throw CalcError.boom
        }
        return "ok"
    }

    @Timed
    func work() -> Int {
        Haruspec.simulateCost(50)
        return 1
    }
}

private enum CalcError: Error { case boom }

final class TracedMacroTests: XCTestCase {
    func testRecordsCallsWithArgsAndReturns() {
        let recorder = TraceRecorder(name: "t")
        let calc = Calc()
        TraceContext.$current.withValue(recorder) {
            _ = calc.add(2, 3)
            calc.noop()
        }
        let events = recorder.trace().events

        XCTAssertEqual(events.map(\.kind), [.call, .ret, .call, .ret])
        XCTAssertEqual(events.map(\.label), ["Calc.add", "Calc.add", "Calc.noop", "Calc.noop"])
        XCTAssertEqual(events[0].payload, ["lhs": 2, "rhs": 3]) // args captured by internal name
        XCTAssertEqual(events[1].payload, .int(5)) // return value captured
        XCTAssertNil(events[2].payload) // no args
        XCTAssertNil(events[3].payload) // void return
    }

    func testTracedMethodPreservesReturnValueAndThrowing() throws {
        let recorder = TraceRecorder(name: "t")
        let calc = Calc()
        try TraceContext.$current.withValue(recorder) {
            XCTAssertEqual(try calc.mayThrow(false), "ok") // original behavior intact
            XCTAssertThrowsError(try calc.mayThrow(true)) // errors still propagate
        }
        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.label), ["Calc.mayThrow", "Calc.mayThrow", "Calc.mayThrow", "Calc.mayThrow"])
        XCTAssertEqual(events[1].payload, .string("ok")) // success return recorded
        // The throwing call still records a ret, tagged with the error.
        if case let .object(members)? = events[3].payload {
            XCTAssertNotNil(members["__threw"])
        } else {
            XCTFail("expected a __threw payload on the throwing return")
        }
    }

    func testInertWithoutActiveCapture() {
        let calc = Calc()
        XCTAssertEqual(calc.add(2, 3), 5) // no capture bound → behaves like a normal method
    }

    func testTimedMethodRecordsSignpostDuration() {
        let recorder = TraceRecorder(name: "t", clock: ManualClock())
        let calc = Calc()
        let result = TraceContext.$current.withValue(recorder) { calc.work() }
        XCTAssertEqual(result, 1) // return value intact

        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.kind), [.call, .signpost, .ret]) // timing baked into the method
        XCTAssertEqual(events[1].label, "Calc.work")
        XCTAssertEqual(events[1].durationTicks, 50)
    }
}
