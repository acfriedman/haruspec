import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// A domain is supposed to describe *the code*: "this is MainActor-isolated", "this runs on the cart
/// queue". For code that declares no isolation at all, there is no such fact — and today the resolver
/// answers with wherever the caller happened to be, which makes the harness part of the measurement.
///
/// That is the same failure `worker-N` had, one level up: a field meant to remove scheduling
/// nondeterminism, reintroducing it.
final class AmbientDomainTests: XCTestCase {
    /// A subject that declares nothing. `MainActor.run` would not do here — that closure genuinely
    /// *is* isolated, and `.main` would be the right answer for it.
    private nonisolated static func record(into recorder: TraceRecorder) {
        TraceContext.$current.withValue(recorder) { Haruspec.marker("work") }
    }

    /// Identical work, two calling contexts. Nothing about the subject differs, so nothing about its
    /// recorded domain should either.
    func testUnisolatedWorkRecordsTheSameDomainFromAnyCaller() async {
        let fromMain = TraceRecorder(name: "from-main")
        await MainActor.run { Self.record(into: fromMain) }

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
/// one frame from the subject, isolated to nothing. Resolving them literally reported `ambient` while
/// the traced call that emitted them reported the actor — one method, two answers, which is incoherent
/// however it is captured.
final class CausalDomainAttributionTests: XCTestCase {
    private actor Checkout {
        let recorder: TraceRecorder
        let notifications: NotificationCenter

        init(recorder: TraceRecorder, notifications: NotificationCenter) {
            self.recorder = recorder
            self.notifications = notifications
        }

        /// The shape `@Traced` expands to: a call, the body, a return.
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
        XCTAssertEqual(marker?.domain, .queue("com.emporium.cart"))
    }
}
