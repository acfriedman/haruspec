@testable import HaruspecCore
import XCTest

/// What the diff says when the *same* event runs on a different isolation domain — the shape every
/// concurrency migration produces, because moving a dispatch queue to an actor migrates every event
/// it touches.
///
/// Before this, such an event failed to align (domain is part of the signature) and surfaced as a
/// missing/unexpected **pair** per event. A cart port measured 12 divergences that way, all pairs,
/// none of them a value change. The pairs said nothing about whether behavior survived the move, and
/// buried the values that would have.
final class DomainMigrationTests: XCTestCase {
    private func note(
        _ seq: Int,
        _ label: String,
        on domain: ConcurrencyDomain,
        _ payload: CanonicalValue? = nil
    ) -> TraceEvent {
        TraceEvent(seq: seq, kind: .notification, label: label, domain: domain, subject: 1, payload: payload)
    }

    private func trace(_ name: String, _ events: [TraceEvent]) -> Trace {
        Trace(name: name, events: events)
    }

    /// One named divergence, not a pair — and the domains it moved between are in the message, since
    /// "which domain now?" is the question a reader has.
    func testAMovedEventIsOneDivergenceNamingBothDomains() {
        let baseline = trace("b", [note(0, "CartDidChange", on: .queue("com.emporium.cart", serial: true))])
        let candidate = trace("c", [note(0, "CartDidChange", on: .actor("CartActor", instance: 1))])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertEqual(diff.divergences.count, 1)
        XCTAssertEqual(diff.divergences.first?.kind, .domainMigration)
        XCTAssertEqual(
            diff.divergences.first?.detail,
            "ran on a different domain (queue(serial):com.emporium.cart → actor:CartActor#1)"
        )
    }

    /// Advisory by default. Gating on the move itself would make the tool red by construction on the
    /// migration it exists to serve.
    func testAMoveAloneDoesNotFailTheVerdict() {
        let baseline = trace("b", [note(0, "CartDidChange", on: .queue("com.emporium.cart", serial: true))])
        let candidate = trace("c", [note(0, "CartDidChange", on: .ambient)])

        XCTAssertEqual(BehavioralDiff.compare(baseline: baseline, candidate: candidate).verdict, .equivalent)
    }

    /// The move is disclosed; the values carried across it are still the contract. This is the
    /// distinction the old pairs destroyed.
    func testValuesStillGateAcrossAMove() {
        let baseline = trace("b", [note(0, "CheckoutDidComplete", on: .main, ["totalCents": 1169])])
        let candidate = trace("c", [note(0, "CheckoutDidComplete", on: .ambient, ["totalCents": 1170])])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertEqual(diff.verdict, .diverged)
        XCTAssertEqual(diff.divergences.map(\.kind), [.domainMigration, .valueMismatch])
        XCTAssertEqual(diff.divergences.filter(\.isGating).map(\.kind), [.valueMismatch])
    }

    /// For a change that claims to preserve threading, the move itself is the finding.
    func testGatingPolicyFailsOnTheMoveAlone() {
        let baseline = trace("b", [note(0, "CartDidChange", on: .main)])
        let candidate = trace("c", [note(0, "CartDidChange", on: .queue("com.emporium.cart", serial: true))])
        let spec = Tolerance(domainMigration: .gating)

        XCTAssertEqual(
            BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: spec).verdict,
            .diverged
        )
    }

    /// `.ignored` restores the pre-migration reading, so the old behaviour stays reachable — and the
    /// test documents what it cost: two divergences saying less than one did.
    func testIgnoredPolicyRestoresTheMissingUnexpectedPair() {
        let baseline = trace("b", [note(0, "CartDidChange", on: .main)])
        let candidate = trace("c", [note(0, "CartDidChange", on: .ambient)])
        let spec = Tolerance(domainMigration: .ignored)

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate, tolerances: spec)

        XCTAssertEqual(Set(diff.divergences.map(\.kind)), [.missingEvent, .unexpectedEvent])
    }

    /// An event that genuinely disappeared must not be explained away as a move — migration matching
    /// only claims a candidate event that is otherwise identical.
    func testARemovedEventIsStillMissingNotMigrated() {
        let baseline = trace("b", [
            note(0, "CartDidChange", on: .main),
            note(1, "Inventory.reserve", on: .main)
        ])
        let candidate = trace("c", [note(0, "CartDidChange", on: .ambient)])

        let diff = BehavioralDiff.compare(baseline: baseline, candidate: candidate)
        let byKind = Dictionary(grouping: diff.divergences, by: \.kind)

        XCTAssertEqual(byKind[.domainMigration]?.map(\.label), ["CartDidChange"])
        XCTAssertEqual(byKind[.missingEvent]?.map(\.label), ["Inventory.reserve"])
    }
}
