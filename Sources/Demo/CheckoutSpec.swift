import Foundation
import HaruspecCore
import HaruspecTrace

/// Drives a fixed, deterministic checkout spec against any `CartService` implementation and
/// returns the captured trace. This is the "replay" half of capture→replay→diff: identical inputs,
/// so any difference in the output trace is attributable to the code, not the driver.
public enum CheckoutSpec {
    /// Runs the canonical spec, capturing a trace under a deterministic clock and a fixed
    /// ``ReceiptIssuer``.
    ///
    /// - Parameters:
    ///   - name: The trace's name, carried into every report about it.
    ///   - makeService: Builds the implementation under test from the notification center it posts to
    ///     and the receipt issuer it uses.
    /// - Returns: The trace of the canonical checkout: two adds, a promo, a removal, and a checkout,
    ///   so identical code gives an identical trace.
    ///
    /// Capture is fully ambient and zero-code on the service side: the stamped protocol's forwarder
    /// records call/args/return against ``TraceContext/current`` (bound here), and an injected
    /// `RecordingNotificationCenter` records a dedicated `NotificationCenter` (isolated, so parallel
    /// runs and system noise can't leak in). The service is a plain business object with no knowledge
    /// of the oracle.
    public static func capture(
        name: String,
        _ makeService: (NotificationCenter, ReceiptIssuer) -> CartService
    ) -> Trace {
        let clock = ManualClock()
        let recorder = TraceRecorder(name: name, clock: clock)
        let center = RecordingNotificationCenter()

        let service = TracedCartService(makeService(center, .fixed()))

        TraceContext.$current.withValue(recorder) {
            service.addItem(sku: "COFFEE", unitPriceCents: 1299, quantity: 2)
            service.addItem(sku: "MUG", unitPriceCents: 899, quantity: 1)
            _ = service.applyPromo("SAVE10")
            service.removeItem(sku: "MUG")
            _ = service.checkout()
        }

        return recorder.trace()
    }

    /// Golden baseline behavior.
    public static func baseline() -> Trace {
        capture(name: "checkout.baseline") { CartServiceV1(center: $0, issuer: $1) }
    }

    /// A behavior-preserving refactor (should verify EQUIVALENT).
    public static func refactor() -> Trace {
        capture(name: "checkout.refactor") { CartServiceV2(center: $0, issuer: $1) }
    }

    /// A subtly-broken change (should be caught as DIVERGED).
    public static func regression() -> Trace {
        capture(name: "checkout.regression") { CartServiceBuggy(center: $0, issuer: $1) }
    }

    /// A feature change: intended new behavior (loyalty points) plus one collateral regression.
    /// Verified in *extension mode* against `intent` — the intended deltas are absorbed, the
    /// collateral one is caught. (See `CartServiceV3`.)
    public static func feature() -> Trace {
        capture(name: "checkout.feature") { CartServiceV3(center: $0, issuer: $1) }
    }

    /// The declared intent for the ``feature()`` change: the loyalty additions were *meant* to happen,
    /// so they must not fail the gate. Anything else the change altered is collateral.
    ///
    /// Both declarations sit on production seams (the notifications the app actually posts), not on
    /// marker payloads. A migration would use ``Intent/none`` instead — parity mode is just the empty
    /// intent.
    public static var intent: Intent {
        Intent {
            Emits("LoyaltyPointsEarned")
            Changes("CheckoutDidComplete", field: "pointsEarned")
        }
    }

    /// The declared comparison for this application: the recompute interval has a small timing
    /// budget, and the two independent post-add notifications may be emitted in either order.
    public static var comparison: Comparison {
        Comparison(
            numericEpsilon: 0,
            timingBudgets: ["CartService.checkout": 50],
            unorderedGroups: [["CartDidChange", "AnalyticsDidTrack"]],
            ignoredKinds: []
        )
    }
}
