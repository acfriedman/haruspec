@testable import HaruspecCore
import XCTest

/// The `.perDomain` comparison — the projection that makes genuinely parallel code diffable.
///
/// The motivating case is committed red in the example app: a task-group port of an operation-queue
/// fan-out whose three branches produce the same values every run but finish in a different order,
/// which the total-order diff reports as a *different counterexample every run*. The projection's
/// whole claim is that scheduler interleaving is not behavior: within an unordered domain only
/// content and counts gate, order stays a contract exactly where the runtime guarantees it, and a
/// guarantee that was *dropped* is its own named, gating divergence rather than noise.
final class ProjectionTests: XCTestCase {
    private let perDomain = Tolerance(concurrency: .perDomain)

    private func effect(
        _ seq: Int,
        _ label: String,
        on domain: ConcurrencyDomain,
        _ payload: CanonicalValue? = nil
    ) -> TraceEvent {
        TraceEvent(seq: seq, kind: .effect, label: label, domain: domain, payload: payload, tier: .semantic)
    }

    private func trace(_ name: String, _ events: [TraceEvent]) -> Trace {
        Trace(name: name, events: events)
    }

    private let delivery = ConcurrencyDomain.queue("com.emporium.delivery", serial: false)
    private let cart = ConcurrencyDomain.queue("com.emporium.cart", serial: true)

    // MARK: - Within one domain

    /// The heart of the mode: a concurrent bucket's internal order carries no signal, so the same
    /// multiset in any order is the same behavior — and the total-order diff calling it a value
    /// mismatch is the false positive being retired.
    func testAConcurrentBucketsOrderIsNotBehavior() {
        let baseline = trace("b", [
            effect(0, "Analytics.track", on: delivery, ["symbol": "mug"]),
            effect(1, "Analytics.track", on: delivery, ["symbol": "waterbottle"]),
            effect(2, "Analytics.track", on: delivery, ["symbol": "wineglass"])
        ])
        let candidate = trace("c", [
            effect(0, "Analytics.track", on: delivery, ["symbol": "wineglass"]),
            effect(1, "Analytics.track", on: delivery, ["symbol": "mug"]),
            effect(2, "Analytics.track", on: delivery, ["symbol": "waterbottle"])
        ])

        let projected = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)
        XCTAssertEqual(projected.verdict, .equivalent)
        XCTAssertTrue(projected.divergences.isEmpty)

        // The same traces under the default total order: three aligned pairs, payloads compared
        // positionally, a manufactured mismatch. This is the divergence-that-isn't the red test pins.
        let total = BehavioralDiff.compare(baseline: baseline, candidate: candidate)
        XCTAssertEqual(total.verdict, .diverged)
    }

    /// A serial queue's order is a runtime guarantee the code may rely on, so within that bucket a
    /// swap is still `reordered` — the projection must not launder real ordering bugs.
    func testASerialBucketsOrderIsStillAContract() {
        let baseline = trace("b", [
            effect(0, "Cart.save", on: cart, ["items": 2]),
            effect(1, "Cart.notify", on: cart, ["items": 2])
        ])
        let candidate = trace("c", [
            effect(0, "Cart.notify", on: cart, ["items": 2]),
            effect(1, "Cart.save", on: cart, ["items": 2])
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertTrue(diff.divergences.contains { $0.kind == .reordered })
    }

    /// Order is dropped only *within* the unordered bucket, never the bucket's contents: a branch
    /// that vanished is still missing, by count, whatever the order.
    func testADroppedBranchIsStillMissingFromAConcurrentBucket() {
        let baseline = trace("b", [
            effect(0, "Analytics.track", on: delivery, ["symbol": "mug"]),
            effect(1, "Analytics.track", on: delivery, ["symbol": "waterbottle"]),
            effect(2, "Analytics.track", on: delivery, ["symbol": "wineglass"])
        ])
        let candidate = trace("c", [
            effect(0, "Analytics.track", on: delivery, ["symbol": "wineglass"]),
            effect(1, "Analytics.track", on: delivery, ["symbol": "mug"])
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertEqual(diff.divergences.map(\.kind), [.missingEvent])
        XCTAssertEqual(diff.divergences.first?.detail.contains("waterbottle"), false) // label, not payload
    }

    /// Multiset matching pairs identical content first, so one genuinely changed value reads as one
    /// `valueMismatch` — not as every branch mismatching because the order shifted around it.
    func testOneChangedValueInAConcurrentBucketIsOneMismatch() {
        let baseline = trace("b", [
            effect(0, "Analytics.track", on: delivery, ["discountCents": 100]),
            effect(1, "Analytics.track", on: delivery, ["discountCents": 200]),
            effect(2, "Analytics.track", on: delivery, ["discountCents": 300])
        ])
        let candidate = trace("c", [
            effect(0, "Analytics.track", on: delivery, ["discountCents": 300]),
            effect(1, "Analytics.track", on: delivery, ["discountCents": 200]),
            effect(2, "Analytics.track", on: delivery, ["discountCents": 999])
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertEqual(diff.divergences.map(\.kind), [.valueMismatch])
        XCTAssertEqual(
            diff.divergences.first?.detail,
            "discountCents: baseline=100 candidate=999"
        )
    }

    // MARK: - Across domains

    /// Two domains' relative interleaving is exactly what the scheduler owns, so swapping it is not a
    /// divergence at all under the projection — and is under the total order.
    func testCrossDomainOrderIsDropped() {
        let baseline = trace("b", [
            effect(0, "Cart.save", on: cart, ["items": 1]),
            effect(1, "Analytics.track", on: .main, ["event": "saved"])
        ])
        let candidate = trace("c", [
            effect(0, "Analytics.track", on: .main, ["event": "saved"]),
            effect(1, "Cart.save", on: cart, ["items": 1])
        ])

        let projected = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)
        XCTAssertEqual(projected.verdict, .equivalent)
        XCTAssertTrue(projected.divergences.isEmpty)

        XCTAssertFalse(
            BehavioralDiff.compare(baseline: baseline, candidate: candidate).divergences.isEmpty
        )
    }

    /// The operation-queue → task-group shape, unordered on both sides: every event migrates domains
    /// (advisory, values matched by content), no guarantee was dropped, and the verdict is stable in
    /// every scheduling — the engine-level restatement of the app's committed-red test going green.
    func testAnUnorderedToUnorderedPortIsEquivalentUnderAnyScheduling() {
        let symbols = ["mug", "waterbottle", "wineglass"]
        let baseline = trace("b", symbols.enumerated().map { index, symbol in
            effect(index, "Analytics.track", on: delivery, ["symbol": .string(symbol)])
        })

        for permutation in [["wineglass", "mug", "waterbottle"], ["waterbottle", "wineglass", "mug"], symbols] {
            let candidate = trace("c", permutation.enumerated().map { index, symbol in
                effect(index, "Analytics.track", on: .ambient, ["symbol": .string(symbol)])
            })

            let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)

            XCTAssertEqual(diff.verdict, .equivalent, "diverged for \(permutation): \(diff.divergences)")
            XCTAssertEqual(diff.divergences.map(\.kind), Array(repeating: .domainMigration, count: 3))
            XCTAssertFalse(diff.divergences.contains { $0.kind == .orderingRelaxed })
        }
    }

    // MARK: - The dropped guarantee

    /// Serial queue → task group drops an ordering guarantee consumers may rely on. The values still
    /// verify as a multiset (either side unordered ⇒ multiset), but the relaxation itself is one
    /// named divergence per domain pair — and it gates: the author may well have meant it, and saying
    /// so is exactly what `Intent` is for.
    func testADroppedOrderingGuaranteeGatesUntilDeclared() {
        let baseline = trace("b", [
            effect(0, "Cart.save", on: cart, ["items": 2]),
            effect(1, "Cart.notify", on: cart, ["items": 2])
        ])
        let candidate = trace("c", [
            effect(0, "Cart.notify", on: .ambient, ["items": 2]),
            effect(1, "Cart.save", on: .ambient, ["items": 2])
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)

        XCTAssertEqual(diff.verdict, .diverged)
        let relaxations = diff.divergences.filter { $0.kind == .orderingRelaxed }
        XCTAssertEqual(relaxations.count, 1)
        XCTAssertEqual(relaxations.first?.label, "com.emporium.cart")
        XCTAssertEqual(
            relaxations.first?.detail,
            "ordering guarantee dropped: queue(serial):com.emporium.cart → ambient (2 events)"
        )
        XCTAssertEqual(diff.divergences.filter(\.isGating).map(\.kind), [.orderingRelaxed])

        let declared = diff.classified(against: Intent(expectedOrderingRelaxations: ["com.emporium.cart"]))
        XCTAssertEqual(declared.verdict, .equivalent)
        XCTAssertEqual(
            declared.divergences.first { $0.kind == .orderingRelaxed }?.classification,
            .intended
        )
    }

    /// Declaring one domain's relaxation does not excuse another's — intent must be specific.
    func testDeclaringOneRelaxationDoesNotExcuseAnother() {
        let checkout = ConcurrencyDomain.queue("com.emporium.checkout", serial: true)
        let baseline = trace("b", [
            effect(0, "Cart.save", on: cart, ["items": 2]),
            effect(1, "Checkout.finish", on: checkout, ["total": 100])
        ])
        let candidate = trace("c", [
            effect(0, "Cart.save", on: .ambient, ["items": 2]),
            effect(1, "Checkout.finish", on: .ambient, ["total": 100])
        ])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)
            .classified(against: Intent(expectedOrderingRelaxations: ["com.emporium.cart"]))

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertEqual(diff.divergences.filter(\.isGating).map(\.label), ["com.emporium.checkout"])
    }

    /// The reverse move gains an ordering nothing promised, which loses no guarantee: a plain
    /// advisory migration, no relaxation, green.
    func testGainedOrderIsNotARelaxation() {
        let baseline = trace("b", [effect(0, "Cart.save", on: .ambient, ["items": 2])])
        let candidate = trace("c", [effect(0, "Cart.save", on: cart, ["items": 2])])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)

        XCTAssertEqual(diff.verdict, .equivalent)
        XCTAssertEqual(diff.divergences.map(\.kind), [.domainMigration])
        XCTAssertFalse(diff.divergences.contains { $0.kind == .orderingRelaxed })
    }

    /// Concurrent queue → task group never promised consumers an order, so nothing was dropped:
    /// discipline is unchanged even though the location moved.
    func testAConcurrentQueueToTaskGroupMoveIsNotARelaxation() {
        let baseline = trace("b", [effect(0, "Analytics.track", on: delivery, ["symbol": "mug"])])
        let candidate = trace("c", [effect(0, "Analytics.track", on: .ambient, ["symbol": "mug"])])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: perDomain)

        XCTAssertEqual(diff.verdict, .equivalent)
        XCTAssertEqual(diff.divergences.map(\.kind), [.domainMigration])
    }
}
