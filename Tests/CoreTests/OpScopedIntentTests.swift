@testable import HaruspecCore
import XCTest

/// The modifiers op identity unlocks: a declaration scoped to an op (`.only(in:)`), bounded per
/// application of it (`.once(per:)`), or placed relative to another event (`.after`, `.before`).
///
/// Every event carries the declared op it was recorded under and the diff stamps each divergence
/// with its event's op. Each modifier narrows: what it rejects stays collateral, and what it cannot
/// check fails closed.
final class OpScopedIntentTests: XCTestCase {
    private let add0 = OpIdentity(label: "add", position: 0)
    private let add1 = OpIdentity(label: "add", position: 1)
    private let checkout = OpIdentity(label: "checkout", position: 2)

    private func event(_ seq: Int, _ label: String, op: OpIdentity?) -> TraceEvent {
        TraceEvent(seq: seq, kind: .notification, label: label, tier: .semantic, op: op)
    }

    /// A real comparison, so the divergences carry the diff's op stamp, plus a runner's evidence.
    private func compare(
        _ baseline: [TraceEvent],
        _ candidate: [TraceEvent]
    ) -> (diff: TraceDiff, evidence: ProbeEvidence) {
        let baselineTrace = Trace(name: "b", events: baseline)
        let candidateTrace = Trace(name: "c", events: candidate)
        return (
            BehavioralDiff.compare(baseline: baselineTrace, candidate: candidateTrace),
            ProbeEvidence(baseline: baselineTrace, candidate: candidateTrace)
        )
    }

    // MARK: - The op rides on the divergence

    func testADivergenceCarriesTheOpOfItsEvent() {
        let run = compare(
            [event(0, "CartDidChange", op: add0), event(1, "Receipt", op: checkout)],
            [event(0, "CartDidChange", op: add0), event(1, "RewardsDidUpdate", op: add0)]
        )
        let byLabel = Dictionary(uniqueKeysWithValues: run.diff.divergences.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["RewardsDidUpdate"]?.kind, .unexpectedEvent)
        XCTAssertEqual(byLabel["RewardsDidUpdate"]?.op, add0, "an emitted event is on the candidate side")
        XCTAssertEqual(byLabel["Receipt"]?.kind, .missingEvent)
        XCTAssertEqual(byLabel["Receipt"]?.op, checkout, "an omitted event is on the baseline side")
    }

    func testTheOpSurvivesTheVerdictJSON() throws {
        let divergence = Divergence(
            kind: .unexpectedEvent,
            label: "X",
            baselineSeq: nil,
            candidateSeq: 3,
            detail: "",
            op: add1
        )
        let data = try JSONEncoder().encode(divergence)
        XCTAssertEqual(try JSONDecoder().decode(Divergence.self, from: data).op, add1)
        XCTAssertEqual(add1.description, "add (op 2)")
    }

    // MARK: - .only(in:)

    func testOnlyInMatchesTheDeclaredOpAndNothingElse() {
        let intent = Intent { Emits("RewardsDidUpdate").only(in: "add") }
        let inAdd = Divergence(
            kind: .unexpectedEvent,
            label: "RewardsDidUpdate",
            baselineSeq: nil,
            candidateSeq: 1,
            detail: "",
            op: add1
        )
        let inCheckout = Divergence(
            kind: .unexpectedEvent,
            label: "RewardsDidUpdate",
            baselineSeq: nil,
            candidateSeq: 1,
            detail: "",
            op: checkout
        )
        let unattributed = Divergence(
            kind: .unexpectedEvent,
            label: "RewardsDidUpdate",
            baselineSeq: nil,
            candidateSeq: 1,
            detail: ""
        )
        XCTAssertTrue(intent.declares(inAdd))
        XCTAssertFalse(intent.declares(inCheckout), "the same event under another op stays collateral")
        XCTAssertFalse(intent.declares(unattributed), "no op on the event — nothing to scope to, so it fails closed")
    }

    func testOnlyInNarrowsValueChangesAndMoves() {
        let intent = Intent {
            Changes("Receipt", field: "total").increases().only(in: "checkout")
            Moves("Inventory.reserve", from: .main, to: .ambient).only(in: "checkout")
        }
        let raised = Divergence(
            kind: .valueMismatch,
            label: "Receipt",
            baselineSeq: 0,
            candidateSeq: 0,
            detail: "",
            field: "total",
            baselineValue: 100,
            candidateValue: 150,
            op: checkout
        )
        var raisedInAdd = raised
        raisedInAdd.op = add0
        XCTAssertTrue(intent.declares(raised))
        XCTAssertFalse(intent.declares(raisedInAdd))

        let moved = Divergence(
            kind: .domainMigration,
            label: "Inventory.reserve",
            baselineSeq: 0,
            candidateSeq: 0,
            detail: "",
            fromDomain: "main",
            toDomain: "ambient",
            op: checkout
        )
        var movedInAdd = moved
        movedInAdd.op = add0
        XCTAssertTrue(intent.declares(moved))
        XCTAssertFalse(intent.declares(movedInAdd))
    }

    // MARK: - .once(per:)

    /// The cardinality tripwire: a second event in the same application of the op means the
    /// declaration does not describe what happened there, so both stay collateral.
    func testOncePerAbsorbsOnePerApplicationAndTripsOnTwo() {
        let intent = Intent { Emits("RewardsDidUpdate").once(per: "add") }
        let baseline = [event(0, "CartDidChange", op: add0), event(1, "CartDidChange", op: add1)]
        let candidate = [
            event(0, "CartDidChange", op: add0),
            event(1, "RewardsDidUpdate", op: add0),
            event(2, "CartDidChange", op: add1),
            event(3, "RewardsDidUpdate", op: add1),
            event(
                4,
                "RewardsDidUpdate",
                op: add1
            )
        ]
        let run = compare(baseline, candidate)
        let classified = run.diff.classified(against: intent, evidence: run.evidence)

        XCTAssertEqual(classified.intendedCount, 1, "the first add emitted exactly one")
        XCTAssertEqual(classified.collateralCount, 2, "the second add emitted two — neither is excused")
        XCTAssertFalse(classified.isEquivalent)
        XCTAssertEqual(
            classified.divergences.filter { $0.classification == .intended }.map(\.op),
            [add0]
        )
    }

    func testOncePerIsAlsoAScope() {
        let intent = Intent { Emits("RewardsDidUpdate").once(per: "add") }
        let inCheckout = Divergence(
            kind: .unexpectedEvent,
            label: "RewardsDidUpdate",
            baselineSeq: nil,
            candidateSeq: 1,
            detail: "",
            op: checkout
        )
        XCTAssertFalse(intent.declares(inCheckout), "once per add says nothing about checkout")
    }

    // MARK: - .after / .before

    func testAfterHoldsOnlyWhenTheAnchorPrecedesWithinTheSameOp() {
        let intent = Intent { Emits("RewardsDidUpdate").after("CartDidChange") }
        let baseline = [event(0, "CartDidChange", op: add0)]

        let ordered = compare(baseline, [event(0, "CartDidChange", op: add0), event(1, "RewardsDidUpdate", op: add0)])
        XCTAssertTrue(ordered.diff.classified(against: intent, evidence: ordered.evidence).isEquivalent)

        let reversed = compare(baseline, [event(0, "RewardsDidUpdate", op: add0), event(1, "CartDidChange", op: add0)])
        XCTAssertFalse(reversed.diff.classified(against: intent, evidence: reversed.evidence).isEquivalent)

        let anchorInAnotherOp = compare(
            baseline,
            [event(0, "CartDidChange", op: add0), event(1, "RewardsDidUpdate", op: checkout)]
        )
        XCTAssertFalse(
            anchorInAnotherOp.diff.classified(against: intent, evidence: anchorInAnotherOp.evidence).isEquivalent,
            "an anchor in an earlier op is not the cause — the position is checked within the op"
        )

        XCTAssertFalse(
            ordered.diff.classified(against: intent).isEquivalent,
            "no traces in hand — a position cannot be checked, so it fails closed"
        )
    }

    func testAPositionSpansTheWholeTraceForAnEventWithNoOp() {
        let intent = Intent { Emits("RewardsDidUpdate").after("CartDidChange") }
        let run = compare(
            [event(0, "CartDidChange", op: nil)],
            [event(0, "CartDidChange", op: nil), event(1, "RewardsDidUpdate", op: nil)]
        )
        XCTAssertTrue(run.diff.classified(against: intent, evidence: run.evidence).isEquivalent)
    }

    func testAnOmittedEventsPositionIsCheckedInTheBaseline() {
        let intent = Intent { Omits("Inventory.reserve").before("CartDidChange") }
        let candidate = [event(0, "CartDidChange", op: add0)]

        let wasBefore = compare(
            [event(0, "Inventory.reserve", op: add0), event(1, "CartDidChange", op: add0)],
            candidate
        )
        XCTAssertTrue(wasBefore.diff.classified(against: intent, evidence: wasBefore.evidence).isEquivalent)

        let wasAfter = compare(
            [event(0, "CartDidChange", op: add0), event(1, "Inventory.reserve", op: add0)],
            candidate
        )
        XCTAssertFalse(wasAfter.diff.classified(against: intent, evidence: wasAfter.evidence).isEquivalent)
    }

    // MARK: - Reorders(_, before:) / (_, after:)

    /// A directed reorder is proved from both sides: the event now sits on the declared side of the
    /// anchor, and sat on the other side in the baseline; any other move stays collateral.
    func testADirectedReorderHoldsOnlyForTheDeclaredDirection() {
        let run = compare(
            [event(0, "A", op: add0), event(1, "B", op: add0), event(2, "C", op: add0)],
            [event(0, "B", op: add0), event(1, "C", op: add0), event(2, "A", op: add0)]
        )
        XCTAssertEqual(run.diff.divergences.map(\.kind), [.reordered])
        XCTAssertEqual(run.diff.divergences.first?.label, "A")

        XCTAssertTrue(run.diff.classified(against: Intent { Reorders("A", after: "C") }, evidence: run.evidence)
            .isEquivalent)
        XCTAssertTrue(run.diff.classified(against: Intent { Reorders("A", after: "B") }, evidence: run.evidence)
            .isEquivalent)
        XCTAssertFalse(run.diff.classified(against: Intent { Reorders("A", before: "C") }, evidence: run.evidence)
            .isEquivalent)
        XCTAssertTrue(
            run.diff.classified(against: Intent { Reorders("A") }, evidence: run.evidence).isEquivalent,
            "undirected still absorbs"
        )
        XCTAssertFalse(
            run.diff.classified(against: Intent { Reorders("A", after: "C") }).isEquivalent,
            "without the traces the direction cannot be proved"
        )
    }
}
