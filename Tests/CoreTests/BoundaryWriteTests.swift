@testable import HaruspecCore
import XCTest

/// Property state on a trace comes two ways, and both gate. A `.snapshot` is the harness reading a
/// property back at the end of a capture — the state contract.
///
/// A `.stateChange` is a write that crossed a boundary (a forwarder's or double's setter) — an
/// interaction, compared like a call.
final class BoundaryWriteTests: XCTestCase {
    func testASnapshotValueMismatchGates() {
        let diff = BehavioralDiff.compare(
            baseline: Trace(name: "legacy", events: [reading(0, "Cart.total", 11)]),
            candidate: Trace(name: "port", events: [reading(0, "Cart.total", 12)])
        )

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .valueMismatch && $0.label == "Cart.total" })
    }

    private func reading(_ seq: Int, _ label: String, _ value: Int64) -> TraceEvent {
        TraceEvent(seq: seq, kind: .snapshot, label: label, payload: .int(value), tier: .semantic)
    }

    func testABoundaryWriteWithAnotherValueGates() {
        let diff = BehavioralDiff.compare(
            baseline: Trace(name: "legacy", events: [write(0, "Printer.copies", 2)]),
            candidate: Trace(name: "port", events: [write(0, "Printer.copies", 3)])
        )

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .valueMismatch && !$0.isAdvisory })
    }

    func testADroppedBoundaryWriteGates() {
        let diff = BehavioralDiff.compare(
            baseline: Trace(name: "legacy", events: [write(0, "Printer.copies", 2)]),
            candidate: Trace(name: "port", events: [])
        )

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .missingEvent && $0.label == "Printer.copies" })
    }

    private func write(_ seq: Int, _ label: String, _ value: Int64) -> TraceEvent {
        TraceEvent(seq: seq, kind: .stateChange, label: label, payload: .int(value), tier: .semantic)
    }
}
