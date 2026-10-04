import HaruspecSpec
import Testing

// The Swift Testing surface a spec's suites use. Its own module, because the engine below it stops
// short of the test runner: only the umbrella, which test targets import, links Testing.

public extension Trait where Self == ConditionTrait {
    /// Stands a campaign suite down during record, census, and settle runs, so the checks of ports
    /// and other subjects never run beside a measurement. Replay keeps them running.
    ///
    ///     @Suite("cart.objc-to-swift", .campaign)
    ///     struct CartMigrationTests { … }
    static var campaign: Self {
        .disabled(
            if: ContinuousMode.standsDownCampaigns(),
            "campaign suites stand down during record, census, and settle runs"
        )
    }
}
