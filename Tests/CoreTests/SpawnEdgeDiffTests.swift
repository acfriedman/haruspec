@testable import HaruspecCore
import XCTest

/// The happens-before pass over recorded spawn edges — comparing the *constraints* the edges imply,
/// not the edges themselves.
///
/// The claim being pinned: `orderingLost` fires only when a baseline synchronization can be proven
/// by neither of the two recorded facts the candidate has — a spawn edge, or program order within
/// one ordered domain. The second proof is what keeps an honest actor port green: `dispatch_async`
/// becoming `await` deletes the edge while *strengthening* the ordering, and calling that a loss
/// would make the pass red on exactly the migration it serves.
final class SpawnEdgeDiffTests: XCTestCase {
    private func event(
        _ seq: Int,
        _ label: String,
        on domain: ConcurrencyDomain,
        spawnedBy: Int? = nil
    ) -> TraceEvent {
        TraceEvent(
            seq: seq,
            kind: .effect,
            label: label,
            domain: domain,
            payload: ["value": 1],
            tier: .semantic,
            spawnedBy: spawnedBy
        )
    }

    private func trace(_ name: String, _ events: [TraceEvent]) -> Trace {
        Trace(name: name, events: events)
    }

    private let cart = ConcurrencyDomain.queue("com.emporium.cart", serial: true)

    private func edgeDivergences(_ diff: TraceDiff) -> [Divergence] {
        diff.divergences.filter { $0.kind == .orderingLost || $0.kind == .orderingAdded }
    }

    /// Same edge on both sides: nothing to say.
    func testAPreservedEdgeIsNoDivergence() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0)
        ])

        XCTAssertTrue(edgeDivergences(BehavioralDiff.compare(baseline: baseline, candidate: candidate)).isEmpty)
    }

    /// The edge is gone and no ordered domain covers the pair: the synchronization was dropped, and
    /// it gates by default — the author may have meant it, and declaring so through `Intent` is the
    /// way back to green, per event, not wholesale.
    func testADroppedEdgeIsOrderingLostAndGatesUntilDeclared() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient)
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertEqual(diff.divergences.filter(\.isGating).map(\.kind), [.orderingLost])
        XCTAssertEqual(
            edgeDivergences(diff).first?.detail,
            "synchronization dropped: Cart.checkout → Inventory.reserve held in baseline "
                + "(spawn edge from #0); the candidate leaves them concurrent"
        )

        let declared = diff.classified(against: Intent(expectedOrderingLosses: ["Inventory.reserve"]))
        XCTAssertEqual(declared.verdict, .equivalent)
        XCTAssertEqual(
            declared.divergences.first { $0.kind == .orderingLost }?.classification,
            .intended
        )
    }

    /// The opt-down for a subject hitting the pass's known over-report (transitive chains are not
    /// chased): `.advisory` keeps the report and drops the gate.
    func testAdvisoryPolicyReportsALossWithoutFailing() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient)
        ])
        let spec = Comparison(spawnEdges: .advisory)

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, comparison: spec)

        XCTAssertEqual(diff.verdict, .equivalent)
        XCTAssertEqual(edgeDivergences(diff).map(\.kind), [.orderingLost])
        XCTAssertTrue(edgeDivergences(diff).allSatisfy(\.isAdvisory))
    }

    /// The actor-port shape: the dispatch edge disappears because the work went synchronous inside
    /// one ordered domain. The constraint survives — more strongly — so this is NOT a loss.
    func testAnEdgeReplacedByProgramOrderIsNotALoss() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: cart, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .main)
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertTrue(
            edgeDivergences(diff).isEmpty,
            "program order in an ordered domain proves the constraint: \(diff.divergences)"
        )
    }

    /// Happens-before is transitive: the candidate keeps the constraint through a chain, an edge onto
    /// work on an ordered queue and that queue's program order, so nothing was dropped.
    func testAConstraintKeptThroughAChainIsNotALoss() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.lookup", on: cart, spawnedBy: 0),
            event(2, "Inventory.reserve", on: cart)
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertTrue(edgeDivergences(diff).isEmpty, "the chain proves the constraint: \(diff.divergences)")
    }

    /// A chain proves nothing through a domain whose order is noise: work after the edge on a concurrent
    /// queue may have run first.
    func testAChainThroughAnUnorderedDomainProvesNothing() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: cart, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.lookup", on: .ambient, spawnedBy: 0),
            event(2, "Inventory.reserve", on: .ambient)
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertEqual(edgeDivergences(diff).map(\.kind), [.orderingLost], "\(diff.divergences)")
    }

    /// The reverse shape: the candidate synchronizes a pair the baseline left concurrent — the
    /// awaited port of fire-and-forget work. A real behavioral change (everything downstream now
    /// waits), so it gates until declared, exactly like a loss.
    func testNewSynchronizationIsOrderingAddedAndGatesUntilDeclared() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0)
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)
        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertEqual(diff.divergences.filter(\.isGating).map(\.kind), [.orderingAdded])

        let declared = diff.classified(against: Intent(expectedOrderingAdditions: ["Inventory.reserve"]))
        XCTAssertEqual(declared.verdict, .equivalent)
    }

    /// A spawner that did not survive alignment makes no edge claim — its absence is already the
    /// finding, and a constraint hanging from a missing event would be double-reported noise.
    func testAnUnmatchedSpawnerMakesNoEdgeClaim() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Inventory.reserve", on: .ambient)
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertTrue(edgeDivergences(diff).isEmpty)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .missingEvent && $0.label == "Cart.checkout" })
    }

    /// `.ignored` turns the pass off entirely: edges recorded, nothing read.
    func testIgnoredPolicyReadsNoEdges() {
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient)
        ])
        let spec = Comparison(spawnEdges: .ignored)

        XCTAssertTrue(
            edgeDivergences(BehavioralDiff.compare(baseline: baseline, candidate: candidate, comparison: spec))
                .isEmpty
        )
    }

    /// The pass rides the projection's alignment too: a pair matched by content inside an unordered
    /// bucket still carries its constraint, and still reports the loss.
    func testEdgesAreComparedThroughMultisetPairs() {
        let perDomain = Comparison(concurrency: .perDomain)
        let baseline = trace("b", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Inventory.reserve", on: .ambient, spawnedBy: 0),
            event(2, "Analytics.track", on: .ambient, spawnedBy: 0)
        ])
        let candidate = trace("c", [
            event(0, "Cart.checkout", on: .main),
            event(1, "Analytics.track", on: .ambient, spawnedBy: 0),
            event(2, "Inventory.reserve", on: .ambient)
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, comparison: perDomain)

        XCTAssertEqual(edgeDivergences(diff).map(\.kind), [.orderingLost])
        XCTAssertEqual(edgeDivergences(diff).first?.label, "Inventory.reserve")
    }
}
