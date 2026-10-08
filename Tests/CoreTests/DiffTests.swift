@testable import HaruspecCore
import XCTest

/// Focused unit tests for the diff primitive, using hand-built traces so each divergence kind and
/// each comparison lever is exercised in isolation.
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

    func testReorderFlaggedByDefaultButSetAsideWhenDeclaredUnordered() {
        // Two independent notifications posted in swapped order.
        let base = trace("base", [note(0, "A"), note(1, "B")])
        let cand = trace("cand", [note(0, "B"), note(1, "A")])

        let strict = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertFalse(strict.isEquivalent)
        XCTAssertTrue(strict.divergences.contains { $0.kind == .reordered })

        let setAside = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            comparison: Comparison(unorderedGroups: [["A", "B"]])
        )
        XCTAssertTrue(setAside.isEquivalent)
    }

    func testTimingRegressionRespectsBudget() {
        let base = trace("base", [TraceEvent(seq: 0, kind: .signpost, label: "work", durationTicks: 100)])
        let slow = trace("slow", [TraceEvent(seq: 0, kind: .signpost, label: "work", durationTicks: 200)])

        // Within budget → equivalent.
        let withinBudget = BehavioralDiff.compare(
            baseline: base,
            candidate: slow,
            comparison: Comparison(timingBudgets: ["work": 150])
        )
        XCTAssertTrue(withinBudget.isEquivalent)

        // Over budget → timing regression.
        let bad = BehavioralDiff.compare(
            baseline: base,
            candidate: slow,
            comparison: Comparison(timingBudgets: ["work": 50])
        )
        XCTAssertEqual(bad.divergences.map(\.kind), [.timingRegression])
    }

    func testNumericEpsilonAbsorbsJitter() {
        let base = trace("base", [call(0, "a", ["ratio": 1.0])])
        let cand = trace("cand", [call(0, "a", ["ratio": 1.0000001])])
        let exact = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertFalse(exact.isEquivalent)
        let setAside = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            comparison: Comparison(numericEpsilon: 0.001)
        )
        XCTAssertTrue(setAside.isEquivalent)
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

    func testAFreshValueDivergesUnderEveryComparison() {
        // No comparison redacts a payload value: a fresh identifier is an uncontrolled seam, injected
        // at its source rather than set aside here.
        let base = trace("base", [call(0, "a", ["id": "UUID-1", "amount": 10])])
        let cand = trace("cand", [call(0, "a", ["id": "UUID-2", "amount": 10])])
        let loosest = Comparison(numericEpsilon: 1, structuralComparison: .advisory, concurrency: .perDomain)
        for comparison in [Comparison.strict, loosest] {
            let diff = BehavioralDiff.compare(baseline: base, candidate: cand, comparison: comparison)
            XCTAssertEqual(diff.divergences.map(\.field), ["id"])
        }
    }

    func testAMintedLookingMismatchIsHintedAsAnUncontrolledSeam() {
        // A plan recorded on an earlier day: every replay reads today's clock, so the mismatch is
        // stable and the verdict DIVERGED. The hint is what points at the clock rather than the code.
        let base = trace("base", [call(0, "a", ["at": "2026-10-03T12:00:00Z",
                                                "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301"])])
        let cand = trace("cand", [call(0, "a", ["at": "2026-10-07T09:30:00Z",
                                                "id": "9C5B94B1-35AD-49BB-B118-8E8FC24ABF80"])])
        let details = BehavioralDiff.compare(baseline: base, candidate: cand).divergences.map(\.detail)

        XCTAssertEqual(details.count, 2)
        XCTAssertTrue(details.contains { $0.hasPrefix("at:") && $0.hasSuffix("inject the clock") }, "\(details)")
        XCTAssertTrue(
            details.contains { $0.hasPrefix("id:") && $0.hasSuffix("inject the identifier's source") },
            "\(details)"
        )
    }

    func testAComputedOrReformattedMismatchCarriesNoHint() {
        let base = trace("base", [call(0, "a", ["total": 10, "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301"])])
        let cand = trace("cand", [call(0, "a", ["total": 11, "id": "3f2504e0-4f89-41d3-9a0c-0305e82c3301"])])
        let details = BehavioralDiff.compare(baseline: base, candidate: cand).divergences.map(\.detail)

        XCTAssertEqual(details.count, 2)
        XCTAssertFalse(
            details.contains { $0.contains("uncontrolled seam") },
            "a lowercased UUID is a format change: \(details)"
        )
    }

    func testANotificationPostedWithoutItsSenderDiverges() {
        let base = trace("base", [note(0, "PlanDidChange", subject: 3)])
        let anonymous = trace("cand", [note(0, "PlanDidChange", subject: nil)])
        let renumbered = trace("cand", [note(0, "PlanDidChange", subject: 5)])

        let diff = BehavioralDiff.compare(baseline: base, candidate: anonymous)
        XCTAssertEqual(diff.divergences.map(\.field), ["object"])
        let renumberedDiff = BehavioralDiff.compare(baseline: base, candidate: renumbered)
        XCTAssertTrue(renumberedDiff.isEquivalent, "ids number by first sight")
    }

    func testIgnoredKindsAreDropped() {
        let base = trace("base", [call(0, "a")])
        let cand = trace("cand", [call(0, "a"), TraceEvent(seq: 1, kind: .custom, label: "telemetry")])
        let strict = BehavioralDiff.compare(baseline: base, candidate: cand)
        XCTAssertFalse(strict.isEquivalent)
        let setAside = BehavioralDiff.compare(
            baseline: base,
            candidate: cand,
            comparison: Comparison(ignoredKinds: [.custom])
        )
        XCTAssertTrue(setAside.isEquivalent)
    }
}
