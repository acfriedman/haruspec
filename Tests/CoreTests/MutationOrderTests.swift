@testable import HaruspecCore
import XCTest

/// The mutation-order tier. Write-order divergences on `.stateChange` events are **advisory by
/// default** — order is contract iff something observes the property between writes, which the
/// engine cannot yet know — while the end-state values still gate unconditionally through
/// `.snapshot` events. A spec opts up to `.gating`, where an intended reorder declares itself via
/// `Reorders(_:)`. And no write timeline compares at all unless BOTH captures could record it
/// (`MutationCapture.full` on both sides) — one side's structural silence must never read as the
/// subject having stopped writing.
final class MutationOrderTests: XCTestCase {
    private func write(_ seq: Int, _ label: String, _ value: Int64) -> TraceEvent {
        TraceEvent(seq: seq, kind: .stateChange, label: label, payload: .int(value), tier: .semantic)
    }

    private func reading(_ seq: Int, _ label: String, _ value: Int64) -> TraceEvent {
        TraceEvent(seq: seq, kind: .snapshot, label: label, payload: .int(value), tier: .semantic)
    }

    private func trace(
        _ name: String,
        capture: MutationCapture = .full,
        _ events: [TraceEvent]
    ) -> Trace {
        Trace(name: name, mutationCapture: capture, events: events)
    }

    /// Baseline writes count-then-total; the candidate computes in the other order.
    private var reorderedWrites: (baseline: Trace, candidate: Trace) {
        (
            trace("legacy", [write(0, "Cart.count", 3), write(1, "Cart.total", 11)]),
            trace("port", [write(0, "Cart.total", 11), write(1, "Cart.count", 3)])
        )
    }

    func testAWriteReorderIsAdvisoryByDefault() {
        let (baseline, candidate) = reorderedWrites
        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertEqual(diff.verdict, .equivalent) // reported, not failed
        XCTAssertFalse(diff.divergences.isEmpty)
        XCTAssertTrue(diff.divergences.allSatisfy(\.isAdvisory))
        XCTAssertTrue(diff.divergences.contains { $0.kind == .reordered })
    }

    func testGatingFailsAnUndeclaredReorder() {
        let (baseline, candidate) = reorderedWrites
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidate,
            tolerances: Tolerance(mutationOrder: .gating)
        )

        XCTAssertEqual(diff.verdict, .diverged)
    }

    func testAGatedReorderIsDeclarableViaReorders() {
        let (baseline, candidate) = reorderedWrites
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidate,
            tolerances: Tolerance(mutationOrder: .gating)
        )
        .classified(against: Intent { Reorders("Cart.count", "Cart.total") })

        XCTAssertEqual(diff.verdict, .equivalent)
        XCTAssertTrue(diff.divergences.contains { $0.classification == .intended })
    }

    func testIgnoredDropsTheWriteTimelineEntirely() {
        let (baseline, candidate) = reorderedWrites
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidate,
            tolerances: Tolerance(mutationOrder: .ignored)
        )

        XCTAssertEqual(diff.verdict, .equivalent)
        XCTAssertTrue(diff.divergences.isEmpty)
    }

    /// The scope: writes to labels outside `observedStateLabels` are a port's private state, not
    /// surface — even under `.gating` they never manufacture a divergence.
    func testUnobservedWritesAreDroppedFromTheDiff() {
        let baseline = trace("legacy", [write(0, "Cart.count", 3)])
        let candidate = trace("port", [write(0, "Cart.count", 3), write(1, "Cart.skuIndex", 9)])
        let scoped = Tolerance(mutationOrder: .gating, observedStateLabels: ["Cart.count"])

        let unscoped = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidate,
            tolerances: Tolerance(mutationOrder: .gating)
        )
        XCTAssertEqual(unscoped.verdict, .diverged) // nil scope compares every recorded write

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: scoped)
        XCTAssertEqual(diff.verdict, .equivalent)
        XCTAssertTrue(diff.divergences.isEmpty)
    }

    /// The capability rule: a side that could only see boundary writes cannot stand behind a write
    /// timeline, so `.stateChange` leaves the diff — even under `.gating`.
    func testWriteTimelinesCompareOnlyBetweenFullCaptures() {
        let baseline = trace("legacy", [write(0, "Cart.count", 3)])
        let candidate = trace("port", capture: .boundary, [])
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidate,
            tolerances: Tolerance(mutationOrder: .gating)
        )

        XCTAssertEqual(diff.verdict, .equivalent)
        XCTAssertTrue(diff.divergences.isEmpty)
    }

    /// The state contract: snapshots are harness-read, so they gate under every capability and every
    /// `mutationOrder` policy — advisory write order never waives the end-state values.
    func testASnapshotValueMismatchGatesRegardless() {
        let baseline = trace("legacy", capture: .none, [reading(0, "Cart.total", 11)])
        let candidate = trace("port", capture: .boundary, [reading(0, "Cart.total", 12)])
        let diff = BehavioralDiff.compare(
            baseline: baseline,
            candidate: candidate,
            tolerances: Tolerance(mutationOrder: .ignored)
        )

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .valueMismatch && $0.label == "Cart.total" })
    }

    /// An aligned pair of writes with different committed values is still only advisory under the
    /// default policy — the disagreement that matters gates through the snapshot, which pins the
    /// value an observer would actually read at the end.
    func testAnIntermediateValueDifferenceRidesTheWritePolicy() {
        let baseline = trace("legacy", [write(0, "Cart.count", 3), reading(1, "Cart.count", 3)])
        let candidate = trace("port", [write(0, "Cart.count", 4), reading(1, "Cart.count", 3)])
        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertEqual(diff.verdict, .equivalent)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .valueMismatch && $0.isAdvisory })
    }
}
