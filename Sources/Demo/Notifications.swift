import Foundation

/// Product notifications the checkout module posts. These are ordinary app notifications — the
/// services have no knowledge of the oracle; `NotificationInterceptor` captures them at runtime.
public extension Notification.Name {
    static let cartDidChange = Notification.Name("CartDidChange")
    static let analyticsDidTrack = Notification.Name("AnalyticsDidTrack")
    static let checkoutDidComplete = Notification.Name("CheckoutDidComplete")
    static let loyaltyPointsEarned = Notification.Name("LoyaltyPointsEarned")
}

/// The set the interceptor allowlists so only product notifications enter the trace.
public let checkoutNotificationNames: Set<String> = [
    "CartDidChange", "AnalyticsDidTrack", "CheckoutDidComplete", "LoyaltyPointsEarned"
]
