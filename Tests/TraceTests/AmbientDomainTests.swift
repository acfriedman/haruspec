import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// A domain is supposed to describe *the code*: "this is MainActor-isolated", "this runs on the cart
/// queue". For code that declares no isolation at all, there is no such fact — and a resolver that
/// answers with wherever the caller happened to be makes the harness part of the measurement.
///
/// That is the same failure `worker-N` had, one level up: a field meant to remove scheduling
/// nondeterminism, reintroducing it.
final class AmbientDomainTests: XCTestCase {
    /// A subject that declares nothing.
    private nonisolated static func record(into recorder: TraceRecorder) {
        TraceContext.$current.withValue(recorder) { Haruspec.marker("work") }
    }

    /// Identical work, two calling contexts. Nothing about the subject differs, so nothing about its
    /// recorded domain should either.
    ///
    /// The main-side caller merely *occupies* main: the standard `resultType:` form of
    /// `MainActor.run` is the one the seam does not claim, so nothing marks the hop as work handed
    /// to the main queue. The claimed form (`MainActor.run { … }`) is a different fact — the subject
    /// delivering onto main — and `.main` is the right answer for it (see `MainActorSeamTests`).
    func testUnisolatedWorkRecordsTheSameDomainFromAnyCaller() async {
        let fromMain = TraceRecorder(name: "from-main")
        await MainActor.run(resultType: Void.self) { Self.record(into: fromMain) }

        let fromPool = TraceRecorder(name: "from-pool")
        await Task.detached { Self.record(into: fromPool) }.value

        XCTAssertEqual(
            fromMain.trace().events.first?.domain,
            fromPool.trace().events.first?.domain,
            "the subject declares no isolation, so its domain must not depend on who called it"
        )
        XCTAssertEqual(fromMain.trace().events.first?.domain, .ambient)
    }
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

/// The one happens-before edge the runtime hands over for free: work that arrived by dispatch or task
/// rather than by being called, and the call that put it there.
final class SpawnEdgeTests: XCTestCase {
    private func cause(of label: String, in recorder: TraceRecorder) -> Int?? {
        recorder.trace().events.first { $0.label == label }.map(\.spawnedBy)
    }

    /// Read at the enqueue, which is the only moment both ends are known — by the time the block runs,
    /// the call that spawned it may already have returned.
    func testDispatchedWorkNamesTheCallThatEnqueuedIt() async {
        let recorder = TraceRecorder(name: "spawn")
        let queue = DispatchQueue(label: "com.emporium.cart")

        TraceContext.$current.withValue(recorder) {
            recorder.call("Cart.checkout")
            queue.async { recorder.marker("reserve-stock") }
            recorder.ret("Cart.checkout")
        }
        let drained = await DispatchSeam.quiesce(timeout: 5)
        XCTAssertTrue(drained)

        let checkoutSeq = recorder.trace().events.first { $0.label == "Cart.checkout" }?.seq
        XCTAssertEqual(cause(of: "reserve-stock", in: recorder), checkoutSeq)
    }

    /// Program order carries the rest: one edge to the block's first event says the whole block
    /// happens after the enqueue, so a second event inside claims nothing.
    func testOnlyTheFirstEventInABlockCarriesTheEdge() async {
        let recorder = TraceRecorder(name: "spawn")
        let queue = DispatchQueue(label: "com.emporium.cart")

        TraceContext.$current.withValue(recorder) {
            recorder.call("Cart.checkout")
            queue.async {
                recorder.marker("first")
                recorder.marker("second")
            }
            recorder.ret("Cart.checkout")
        }
        _ = await DispatchSeam.quiesce(timeout: 5)

        XCTAssertNotNil(cause(of: "first", in: recorder) ?? nil)
        XCTAssertNil(cause(of: "second", in: recorder) ?? nil)
    }

    /// An unawaited `Task` is a spawn too, and the task path carries the cause in a task-local rather
    /// than a thread-local — `Thread.current` is unavailable where that binding has to be made.
    func testAnUnawaitedTaskAlsoNamesItsCause() async {
        let recorder = TraceRecorder(name: "spawn-task")

        TraceContext.$current.withValue(recorder) {
            recorder.call("Cart.checkout")
            Task { recorder.marker("deferred") }
            recorder.ret("Cart.checkout")
        }
        _ = await DispatchSeam.quiesce(timeout: 5)

        XCTAssertEqual(cause(of: "deferred", in: recorder), recorder.trace().events.first?.seq)
    }

    /// Canonicalization re-densifies every `seq`, and an edge *is* a `seq`. Dropping a kind must move
    /// the edges with it rather than leave them pointing at whichever event inherited the number.
    func testEdgesSurviveCanonicalRenumbering() {
        let raw = Trace(name: "t", events: [
            TraceEvent(seq: 0, kind: .custom, label: "noise"),
            TraceEvent(seq: 1, kind: .call, label: "Cart.checkout"),
            TraceEvent(seq: 2, kind: .marker, label: "reserve", tier: .semantic, spawnedBy: 1)
        ])

        let canonical = Canonicalizer.canonicalize(raw, spec: Tolerance(ignoredKinds: [.custom]))

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

        let canonical = Canonicalizer.canonicalize(raw, spec: Tolerance(ignoredKinds: [.custom]))

        XCTAssertNil(canonical.events.first?.spawnedBy)
    }
}
