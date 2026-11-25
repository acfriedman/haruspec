import Foundation
import HaruspecCore

// Environment seam — docs/seams.md: Locale / TimeZone / Calendar. An injected, cassette-backed value seam:
// the same shape as SeamClock/SeamDefaults, reads recorded once and replayed identically.

/// Locale/timezone/calendar reads, recorded/replayed. High-value for the UI configuration-sweep
/// application, where the same code is exercised across many locales — each captured deterministically.
public struct SeamEnvironment {
    private let cassette: Cassette
    private let seam: String

    public init(cassette: Cassette, seam: String = "env") {
        self.cassette = cassette
        self.seam = seam
    }

    public func localeIdentifier(live: () -> String = { Locale.current.identifier }) -> String {
        cassette.string(seam: "\(seam).locale", live: live) ?? ""
    }

    public func timeZoneIdentifier(live: () -> String = { TimeZone.current.identifier }) -> String {
        cassette.string(seam: "\(seam).timezone", live: live) ?? ""
    }

    public func calendarIdentifier(live: () -> String = { "\(Calendar.current.identifier)" }) -> String {
        cassette.string(seam: "\(seam).calendar", live: live) ?? ""
    }

    /// Returns the reconstructed Foundation locale, for code that wants the type rather than the identifier.
    ///
    /// - Returns: The locale whose identifier ``localeIdentifier(live:)`` returns, with the live read
    ///   taken from ``Foundation/Locale/current``.
    public func locale() -> Locale {
        Locale(identifier: localeIdentifier())
    }

    public func timeZone() -> TimeZone {
        TimeZone(identifier: timeZoneIdentifier()) ?? .current
    }
}
