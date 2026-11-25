import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

final class AmbientDomainTests: XCTestCase {
    /// Identical work, two calling contexts. Nothing about the subject differs, so nothing about its
    /// recorded domain should either.
    ///
    /// The main-side caller merely *occupies* main: nothing handed the subject's work to the main
    /// queue. Work a subject hands to its own main-queue seam is a different fact, and `.main` is the
    /// right answer for it (see `WorkBacklogTests`).
    func testUnisolatedWorkRecordsTheSameDomainFromAnyCaller() async {
        let fromMain = TraceRecorder(name: "from-main")
        await MainActor.run(resultType: Void.self) { recordUndeclaredWork(into: fromMain) }

        let fromPool = TraceRecorder(name: "from-pool")
        await Task.detached { recordUndeclaredWork(into: fromPool) }.value

        XCTAssertEqual(
            fromMain.trace().events.first?.domain,
            fromPool.trace().events.first?.domain,
            "the subject declares no isolation, so its domain must not depend on who called it"
        )
        XCTAssertEqual(fromMain.trace().events.first?.domain, .ambient)
    }

    /// Inside a capture whose own frames run off main, the main thread is the subject's doing, so
    /// undeclared work there records `main`; off main it stays `ambient`.
    func testAVouchingCaptureReadsTheMainThreadAsMain() async {
        let recorder = TraceRecorder(name: "vouched")

        await TraceContext.$capturesOffMain.withValue(true) {
            await MainActor.run(resultType: Void.self) { recordUndeclaredWork(into: recorder) }
            // This test is nonisolated `async`, so it runs off main; a detached task would drop the
            // binding.
            recordUndeclaredWork(into: recorder)
        }

        XCTAssertEqual(recorder.trace().events.map(\.domain), [.main, .ambient])
    }
}

/// Records a `work` marker from a subject that declares nothing.
///
/// - Parameter recorder: The recorder the marker is recorded into.
///
/// A domain is supposed to describe *the code*: "this is MainActor-isolated", "this runs on the cart
/// queue". For code that declares no isolation at all, there is no such fact — and a resolver that
/// answers with wherever the caller happened to be makes the harness part of the measurement.
///
/// That is the same failure `worker-N` had, one level up: a field meant to remove scheduling
/// nondeterminism, reintroducing it.
private func recordUndeclaredWork(into recorder: TraceRecorder) {
    TraceContext.$current.withValue(recorder) { Haruspec.marker("work") }
}

/// An effect belongs to the work that caused it, not to the machinery that carried it there.
///
/// A notification travels through Foundation and a collaborator call through a decorator; both arrive
/// one frame from the subject, isolated to nothing. Resolving them literally would report `ambient`
/// while the traced call that emitted them reports the actor — one method, two answers, which is
/// incoherent however it is captured.
final class CausalDomainAttributionTests: XCTestCase {
    private actor Checkout {
        let recorder: TraceRecorder
        let notifications: NotificationCenter

        init(recorder: TraceRecorder, notifications: NotificationCenter) {
            self.recorder = recorder
            self.notifications = notifications
        }

        /// The shape a forwarder expands to: a call, the body, a return.
        func run() {
            recorder.call("Checkout.run", subject: self)
            notifications.post(name: Notification.Name("CheckoutDidComplete"), object: nil)
            recorder.ret("Checkout.run", subject: self)
        }
    }

    func testAnEffectInheritsTheDomainOfTheCallThatEmittedIt() async {
        let recorder = TraceRecorder(name: "attribution")
        let center = RecordingNotificationCenter()

        await TraceContext.$current.withValue(recorder) {
            await Checkout(recorder: recorder, notifications: center).run()
        }

        let domains = recorder.trace().events.map { ($0.label, $0.domain) }
        XCTAssertEqual(
            Set(domains.map(\.1)),
            [.actor("Checkout", instance: 1)],
            "one method emitted all of it, so one domain describes all of it: \(domains)"
        )
    }

    /// Inheritance is a fallback, never an override: an event that knows its own domain keeps it.
    func testAnEventWithItsOwnDomainIsNotOverriddenByItsCaller() async {
        let recorder = TraceRecorder(name: "no-override")
        let queue = DispatchQueue(label: "com.emporium.cart")

        await TraceContext.$current.withValue(recorder) {
            await Checkout(recorder: recorder, notifications: RecordingNotificationCenter()).run()
            queue.sync { recorder.marker("on-its-own-queue") }
        }

        let marker = recorder.trace().events.first { $0.label == "on-its-own-queue" }
        XCTAssertEqual(marker?.domain, .queue("com.emporium.cart", serial: true))
    }
}

/// The spawn edge survives canonicalization. (The edge itself is read at the enqueue by the
/// `WorkBacklog`; see `WorkBacklogTests`.)
final class SpawnEdgeTests: XCTestCase {
    /// Canonicalization re-densifies every `seq`, and an edge *is* a `seq`. Dropping a kind must move
    /// the edges with it rather than leave them pointing at whichever event inherited the number.
    func testEdgesSurviveCanonicalRenumbering() {
        let raw = Trace(name: "t", events: [
            TraceEvent(seq: 0, kind: .custom, label: "noise"),
            TraceEvent(seq: 1, kind: .call, label: "Cart.checkout"),
            TraceEvent(seq: 2, kind: .marker, label: "reserve", tier: .semantic, spawnedBy: 1)
        ])

        let canonical = Canonicalizer.canonicalize(raw, comparison: Comparison(ignoredKinds: [.custom]))

        let checkout = canonical.events.first { $0.label == "Cart.checkout" }
        let reserve = canonical.events.first { $0.label == "reserve" }
        XCTAssertEqual(checkout?.seq, 0, "the dropped event's number was reclaimed")
        XCTAssertEqual(reserve?.spawnedBy, 0, "and the edge followed its cause rather than the number")
    }

    /// An edge whose cause was filtered out is dropped, not left dangling — a fabricated causal claim
    /// is worse than a missing one.
    func testAnEdgeToAFilteredCauseIsDropped() {
        let raw = Trace(name: "t", events: [
            TraceEvent(seq: 0, kind: .custom, label: "spawner"),
            TraceEvent(seq: 1, kind: .marker, label: "spawned", tier: .semantic, spawnedBy: 0)
        ])

        let canonical = Canonicalizer.canonicalize(raw, comparison: Comparison(ignoredKinds: [.custom]))

        XCTAssertNil(canonical.events.first?.spawnedBy)
    }
}
