import Foundation
import HaruspecCore

// Randomness seam — SEAMS.md: `SystemRandomNumberGenerator`, `Int.random`, `arc4random`. An injected,
// cassette-backed value seam: the entropy stream is recorded once and replayed identically.

/// A `RandomNumberGenerator` whose stream is recorded/replayed. Drop it into any `random(in:using:)`
/// call — `Int.random(in: 0..<10, using: &rng)` — and the sequence is fixed across replays. Also the
/// substrate for property-based generation at the seam (see SEAMS.md).
public struct SeamRNG: RandomNumberGenerator {
    private let cassette: Cassette
    private let seam: String

    public init(cassette: Cassette, seam: String = "rng") {
        self.cassette = cassette
        self.seam = seam
    }

    public mutating func next() -> UInt64 {
        // `SystemRandomNumberGenerator` has no user-visible state, so producing fresh entropy per call
        // is correct even though the closure captures a copy.
        let raw = cassette.int(seam: seam, live: {
            var system = SystemRandomNumberGenerator()
            return Int64(bitPattern: system.next())
        })
        return UInt64(bitPattern: raw)
    }
}
