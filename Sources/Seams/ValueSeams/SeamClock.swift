import Foundation
import HaruspecCore

// Time seam — SEAMS.md: `Date()` / `Date.now`. One of the injected, cassette-backed value seams: a
// `live` source recorded once on the golden run and replayed identically thereafter, through a clean
// injected boundary (zero intrusiveness). Reaching the same seam at an *un-injected* call-site (a bare
// `Date()`) is the later source-shim / swizzle mechanism, layered on this same cassette.

/// A clock whose readings are recorded/replayed. Stands in for production reading wall-clock time.
/// Record once and two replays return the *same* timestamps — nondeterministic time becomes diffable.
public struct SeamClock {
    private let cassette: Cassette
    private let seam: String
    private let live: () -> Double

    public init(cassette: Cassette, seam: String = "clock",
                live: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.cassette = cassette
        self.seam = seam
        self.live = live
    }

    /// Seconds since the epoch — recorded on the golden run, replayed identically thereafter.
    public func now() -> Double { cassette.double(seam: seam, live: live) }

    /// A `Date` view of `now()`, for code that wants the Foundation type.
    public func date() -> Date { Date(timeIntervalSince1970: now()) }
}
