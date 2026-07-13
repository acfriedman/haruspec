import Foundation
import OracleCore

/// The ambient provider that `@Seamed`-rewritten call-sites route through, so the harness can reach
/// **un-injected** nondeterminism — a bare `Date()` / `UUID()` in legacy code that takes no injected
/// clock or generator.
///
/// Bind a `Cassette` for the dynamic scope of a run and the rewritten calls record or replay through
/// it; with nothing bound the provider is a transparent passthrough to the real API, so production
/// behavior is unchanged (and `@Seamed` only rewrites under `#if DEBUG` anyway).
public enum OracleSeam {
    @TaskLocal public static var cassette: Cassette?

    /// Run `body` with `cassette` bound as the ambient seam source (record or replay). Rewritten seam
    /// calls inside route through it; calls outside any binding stay live.
    @discardableResult
    public static func bind<T>(_ cassette: Cassette, _ body: () throws -> T) rethrows -> T {
        try $cassette.withValue(cassette, operation: body)
    }

    /// Replacement for a bare `Date()` / `Date.now`.
    public static func now() -> Date {
        guard let cassette else { return Date() }
        return Date(timeIntervalSince1970: cassette.double(seam: "seam.date", live: { Date().timeIntervalSince1970 }))
    }

    /// Replacement for a bare `UUID()`.
    public static func uuid() -> UUID {
        guard let cassette else { return UUID() }
        let recorded = cassette.string(seam: "seam.uuid", live: { UUID().uuidString })
        return recorded.flatMap(UUID.init(uuidString:)) ?? UUID()
    }
}
