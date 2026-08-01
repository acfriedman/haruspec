@testable import HaruspecCore
import XCTest

/// Focused unit tests for the diff primitive, using hand-built traces so each divergence kind and
/// each tolerance lever is exercised in isolation.
final class DiffTests: XCTestCase {
    /// Small builders for readability.
    private func call(
        _ seq: Int,
        _ label: String,
        _ payload: CanonicalValue? = nil,
        subject: Int? = 1
    ) -> TraceEvent {
        TraceEvent(seq: seq, kind: .call, label: label, subject: subject, payload: payload)
    }

    private func note(
        _ seq: Int,
        _ label: String,
        _ payload: CanonicalValue? = nil,
        subject: Int? = 1
    ) -> TraceEvent {
        TraceEvent(seq: seq, kind: .notification, label: label, subject: subject, payload: payload)
    }

    private func trace(_ name: String, _ events: [TraceEvent]) -> Trace {
        Trace(name: name, events: events)
    }

    func testIdenticalTracesAreEquivalent() {
        let identical = trace("t", [call(0, "a", ["x": 1]), note(1, "N"), call(2, "b")])
        let diff = BehavioralDiff.compare(baseline: identical, candidate: identical)
        XCTAssertTrue(diff.isEquivalent)
        XCTAssertEqual(diff.divergences.count, 0)
    }

    func testValueMismatchIsReported() {
        let base = trace("base", [call(0, "a", ["x": 1])])
        let cand = trace("cand", [call(0, "a", ["x": 2])])
        let diff = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertFalse(diff.isEquivalent)
        XCTAssertEqual(diff.divergences.map(\.kind), [.valueMismatch])
        XCTAssertTrue(diff.divergences[0].detail.contains("x: baseline=1 candidate=2"))
    }

    func testMissingEventIsReported() {
        let base = trace("base", [call(0, "a"), note(1, "N"), call(2, "b")])
        let cand = trace("cand", [call(0, "a"), call(1, "b")])
        let diff = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertEqual(diff.divergences.map(\.kind), [.missingEvent])
        XCTAssertEqual(diff.divergences[0].label, "N")
    }

    func testUnexpectedEventIsReported() {
        let base = trace("base", [call(0, "a"), call(1, "b")])
        let cand = trace("cand", [call(0, "a"), note(1, "N"), call(2, "b")])
        let diff = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertEqual(diff.divergences.map(\.kind), [.unexpectedEvent])
        XCTAssertEqual(diff.divergences[0].label, "N")
    }

    func testReorderFlaggedByDefaultButToleratedWhenDeclaredUnordered() {
        // Two independent notifications posted in swapped order.
        let base = trace("base", [note(0, "A"), note(1, "B")])
        let cand = trace("cand", [note(0, "B"), note(1, "A")])

        let strict = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertFalse(strict.isEquivalent)
        XCTAssertTrue(strict.divergences.contains { $0.kind == .reordered })

        let tolerant = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            tolerances: ToleranceSpec(unorderedGroups: [["A", "B"]])
        )
        XCTAssertTrue(tolerant.isEquivalent)
    }

    func testTimingRegressionRespectsBudget() {
        let base = trace("base", [TraceEvent(seq: 0, kind: .signpost, label: "work", durationTicks: 100)])
        let slow = trace("slow", [TraceEvent(seq: 0, kind: .signpost, label: "work", durationTicks: 200)])

        // Within budget → equivalent.
        let withinBudget = BehavioralDiff.compare(
            baseline: base,
            candidate: slow,
            tolerances: ToleranceSpec(timingBudgets: ["work": 150])
        )
        XCTAssertTrue(withinBudget.isEquivalent)

        // Over budget → timing regression.
        let bad = BehavioralDiff.compare(
            baseline: base,
            candidate: slow,
            tolerances: ToleranceSpec(timingBudgets: ["work": 50])
        )
        XCTAssertEqual(bad.divergences.map(\.kind), [.timingRegression])
    }

    func testNumericEpsilonAbsorbsJitter() {
        let base = trace("base", [call(0, "a", ["ratio": 1.0])])
        let cand = trace("cand", [call(0, "a", ["ratio": 1.0000001])])
        let exact = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertFalse(exact.isEquivalent)
        let tolerant = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            tolerances: ToleranceSpec(numericEpsilon: 0.001)
        )
        XCTAssertTrue(tolerant.isEquivalent)
    }

    func testAlignmentIgnoresSubjectOrdinal() {
        // Subject is a per-trace symbolic ordinal (order-of-first-appearance), not comparable across
        // two independently-run traces. The adapter case: baseline posts as itself (subject 1) while a
        // candidate posts via a wrapped inner object that appears in a different order (subject 2).
        // Same kind+label+payload ⇒ same signal ⇒ must align with zero divergences.
        let base = trace("base", [note(0, "N", ["v": 1], subject: 1)])
        let cand = trace("cand", [note(0, "N", ["v": 1], subject: 2)])
        let diff = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertTrue(diff.isEquivalent)
        XCTAssertEqual(diff.divergences.count, 0)
    }

    func testVolatileFieldsAreRedactedAway() {
        let base = trace("base", [call(0, "a", ["id": "UUID-1", "amount": 10])])
        let cand = trace("cand", [call(0, "a", ["id": "UUID-2", "amount": 10])])
        let strict = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertFalse(strict.isEquivalent) // ids differ
        let tolerant = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            tolerances: ToleranceSpec(volatileFields: [.key("id")])
        )
        XCTAssertTrue(tolerant.isEquivalent) // id redacted, amount matches
    }

    func testLabelScopedVolatileFieldDoesNotRedactOtherEvents() {
        // "id" is a fresh UUID in checkout but a stable product identifier in addItem. A rule scoped
        // to checkout must tolerate the former while still catching a regression in the latter.
        let base = trace("base", [call(0, "addItem", ["id": "SKU-7"]),
                                  call(1, "checkout", ["id": "UUID-1"])])
        let cand = trace("cand", [call(0, "addItem", ["id": "SKU-9"]),
                                  call(1, "checkout", ["id": "UUID-2"])])

        let scoped = ToleranceSpec(volatileFields: [.key("id", inEvent: "checkout")])
        let diff = BehavioralDiff.compare(baseline: base, candidate: cand, tolerances: scoped)
        XCTAssertEqual(diff.divergences.map(\.kind), [.valueMismatch]) // addItem's id still compared
        XCTAssertEqual(diff.divergences[0].label, "addItem")

        // An unscoped rule would have swallowed both.
        let unscoped = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            tolerances: ToleranceSpec(volatileFields: [.key("id")])
        )
        XCTAssertTrue(unscoped.isEquivalent)
    }

    func testPathScopedVolatileFieldOnlyRedactsAtThatPath() {
        // "issuedAt" under receipt is clock noise; "issuedAt" under promotion is fixed campaign data.
        let base = trace("base", [call(0, "checkout", ["receipt": ["issuedAt": "t1"],
                                                       "promotion": ["issuedAt": "June"]])])
        let cand = trace("cand", [call(0, "checkout", ["receipt": ["issuedAt": "t2"],
                                                       "promotion": ["issuedAt": "July"]])])

        let scoped = ToleranceSpec(volatileFields: [.path("receipt.issuedAt")])
        let diff = BehavioralDiff.compare(baseline: base, candidate: cand, tolerances: scoped)
        XCTAssertEqual(diff.divergences.map(\.kind), [.valueMismatch]) // promotion.issuedAt still compared

        // Widening the rule to the bare key redacts both and the traces become equivalent.
        let unscoped = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            tolerances: ToleranceSpec(volatileFields: [.key("issuedAt")])
        )
        XCTAssertTrue(unscoped.isEquivalent)
    }

    func testIgnoredKindsAreDropped() {
        let base = trace("base", [call(0, "a")])
        let cand = trace("cand", [call(0, "a"), TraceEvent(seq: 1, kind: .custom, label: "telemetry")])
        let strict = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertFalse(strict.isEquivalent)
        let tolerant = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            tolerances: ToleranceSpec(ignoredKinds: [.custom])
        )
        XCTAssertTrue(tolerant.isEquivalent)
    }
}
