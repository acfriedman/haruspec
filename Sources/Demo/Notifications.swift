import Foundation

/// Product notifications the checkout module posts. These are ordinary app notifications — the
/// services have no knowledge of the oracle; an injected `RecordingNotificationCenter` records them.
public extension Notification.Name {
    static let cartDidChange = Notification.Name("CartDidChange")
    static let analyticsDidTrack = Notification.Name("AnalyticsDidTrack")
    static let checkoutDidComplete = Notification.Name("CheckoutDidComplete")
    static let loyaltyPointsEarned = Notification.Name("LoyaltyPointsEarned")
}
