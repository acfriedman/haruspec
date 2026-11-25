@testable import HaruspecCore
@testable import HaruspecSeams
import XCTest

/// The record → replay → diff loop on real nondeterminism seams (time + randomness + a config read).
///
/// This is the seam-harness analogue of the engine's validation gate: record the boundary
/// once, replay the *same* transcript into both branches, and any divergence is the code's, not the
/// environment's.
final class SeamReplayTests: XCTestCase {
    /// Without a cassette (record mode passes through to live), the seams are genuinely
    /// nondeterministic — so the determinism proven below is meaningful, not vacuous.
    func testLiveRunsAreNondeterministic() {
        XCTAssertNotEqual(
            fingerprint(Cassette()),
            fingerprint(Cassette()),
            "wall clock + system RNG differ run to run"
        )
    }

    /// Record once; replay reproduces the golden run exactly, and any number of replays agree.
    func testRecordOnceReplayBothIsDeterministic() {
        let recording = Cassette()
        let golden = fingerprint(recording)
        let data = recording.snapshot()

        XCTAssertEqual(fingerprint(Cassette(replaying: data)), golden, "replay reproduces the golden run")
        XCTAssertEqual(
            fingerprint(Cassette(replaying: data)),
            fingerprint(Cassette(replaying: data)),
            "the same cassette yields identical output across independent runs"
        )
    }

    /// The payoff: under the *same* recorded inputs, a logic change diverges — attributable to the
    /// code, because the environment was held identical by replay.
    func testCodeChangeIsCaughtUnderSameCassette() {
        let recording = Cassette()
        _ = fingerprint(recording)
        let data = recording.snapshot()

        XCTAssertNotEqual(
            fingerprint(Cassette(replaying: data)),
            fingerprintChanged(Cassette(replaying: data)),
            "identical inputs, changed logic → divergence attributable to the code"
        )
    }

    /// Returns the output of the same seams and inputs under *different logic* (doubles each random
    /// draw) — a code change.
    ///
    /// - Parameter cassette: The cassette the seams replay from or record to.
    /// - Returns: The clock reading, three doubled random draws, and the `region` default, in that order.
    private func fingerprintChanged(_ cassette: Cassette) -> [CanonicalValue] {
        let clock = SeamClock(cassette: cassette)
        var rng = SeamRNG(cassette: cassette)
        let defaults = SeamDefaults(cassette: cassette)
        var out: [CanonicalValue] = [.double(clock.now())]
        for _ in 0 ..< 3 {
            out.append(.int(Int64(Int.random(in: 0 ..< 1_000_000, using: &rng) * 2)))
        }
        out.append(.string(defaults.string(forKey: "region", live: { "US" }) ?? "?"))
        return out
    }

    /// The recorded transcript survives a serialize → reload round-trip, so a cassette captured on the
    /// golden branch can be replayed in a separate process/branch.
    func testCassetteReplaysAfterReload() throws {
        let recording = Cassette()
        let golden = fingerprint(recording)
        let reloaded = try CassetteData(jsonData: recording.snapshot().jsonData())
        XCTAssertEqual(fingerprint(Cassette(replaying: reloaded)), golden)
    }

    /// Returns the observable output of a stand-in for production code that reads three seams.
    ///
    /// - Parameter cassette: The cassette the seams replay from or record to.
    /// - Returns: The clock reading, three random draws in `0 ..< 1_000_000`, and the `region` default,
    ///   in that order.
    private func fingerprint(_ cassette: Cassette) -> [CanonicalValue] {
        let clock = SeamClock(cassette: cassette)
        var rng = SeamRNG(cassette: cassette)
        let defaults = SeamDefaults(cassette: cassette)
        var out: [CanonicalValue] = [.double(clock.now())]
        for _ in 0 ..< 3 {
            out.append(.int(Int64(Int.random(in: 0 ..< 1_000_000, using: &rng))))
        }
        out.append(.string(defaults.string(forKey: "region", live: { "US" }) ?? "?"))
        return out
    }
}
