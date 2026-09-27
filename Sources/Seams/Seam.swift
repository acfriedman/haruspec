import Foundation
import HaruspecCore

/// The ambient cassette a hand-written seam routes through, so the harness can reach nondeterminism
/// nothing hands in — a swizzled Obj-C singleton's `deviceToken`, read inside the swizzle as
/// `Seam.cassette?.string(seam:live:)`.
///
/// Bind a `Cassette` for the dynamic scope of a run and those reads record or replay through it; with
/// nothing bound a seam falls through to the real API, so production behavior is unchanged.
public enum Seam {
    @TaskLocal public static var cassette: Cassette?

    /// Runs `body` with `cassette` bound as the ambient seam source (record or replay). Seam reads
    /// inside route through it; reads outside any binding stay live.
    @discardableResult
    public static func bind<T>(_ cassette: Cassette, _ body: () throws -> T) rethrows -> T {
        try $cassette.withValue(cassette, operation: body)
    }
}
