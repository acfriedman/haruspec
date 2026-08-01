@testable import HaruspecCore
@testable import HaruspecSeams
@testable import HaruspecTrace
import XCTest

/// Coverage is where the seam harness stops being a capability and becomes a *trustworthy gate*. The
/// `Cassette` already surfaces `SeamMiss`es (unrecorded interactions during replay); this suite proves
/// those flow into an `HaruspecCore.Coverage` and, via `VerificationResult`, downgrade an EQUIVALENT the
/// oracle can't stand behind to CANNOT-VERIFY — the soundness the whole three-tier verdict exists for.
final class SeamCoverageTests: XCTestCase {
    // MARK: - The adapter (Cassette → Coverage)

    func testAdapterMapsHitsMissesAndUnexercised() {
        // Record two seams; replay hits both, then over-reads `b` (a miss). A third seam `c` is declared
        // in the registry but never reached this run.
        let recording = Cassette()
        _ = recording.int(seam: "a", live: { 1 })
        _ = recording.int(seam: "b", live: { 2 })
        let tape = recording.snapshot()

        let replay = Cassette(replaying: tape)
        _ = replay.int(seam: "a", live: { 0 }) // hit
        _ = replay.int(seam: "b", live: { 0 }) // hit
        _ = replay.int(seam: "b", live: { 99 }) // recording exhausted → miss on b#1 (live fallback)

        let cov = replay.coverage(declaring: ["a", "b", "c"])
        XCTAssertEqual(cov.declared, ["a", "b", "c"])
        XCTAssertEqual(cov.exercised, ["a"], "b fell back to live, c was never reached")
        XCTAssertEqual(cov.unrecordedReach.map(\.boundary), ["b"])
        XCTAssertEqual(cov.gaps.filter { $0.reason == .unexercised }.map(\.boundary), ["c"])
        XCTAssertFalse(cov.trustsEquivalent, "a live fallback means the environment wasn't held identical")
    }

    func testDefaultRegistryIsTheRecordedTracks() {
        let recording = Cassette()
        _ = recording.int(seam: "a", live: { 1 })
        _ = recording.int(seam: "b", live: { 2 })

        let replay = Cassette(replaying: recording.snapshot())
        _ = replay.int(seam: "a", live: { 0 })
        _ = replay.int(seam: "b", live: { 0 })

        let cov = replay.coverage() // no explicit registry → the golden's recorded seams
        XCTAssertEqual(cov.declared, ["a", "b"])
        XCTAssertEqual(cov.exercised, ["a", "b"])
        XCTAssertEqual(cov.fraction, 1.0)
        XCTAssertTrue(cov.trustsEquivalent)
    }

    // MARK: - End to end: coverage prevents a false EQUIVALENT

    /// "Production" logic reads a clock + a discount from the cassette and posts the total. With
    /// `extraSeam`, the *changed* branch reaches a new boundary (a surcharge flag) the golden never
    /// recorded — and whose value happens to be 0 in this environment, so the observable trace is
    /// *identical*. The trace diff alone would call that EQUIVALENT (a false pass); coverage must catch
    /// the unrecorded boundary and abstain.
    private func runSession(cassette: Cassette, extraSeam: Bool) -> Trace {
        let recorder = TraceRecorder(name: "session", clock: ManualClock())
        let center = NotificationCenter()
        let interceptor = NotificationInterceptor(
            recorder: recorder,
            center: center,
            names: ["CheckoutCompleted"]
        )
        interceptor.start(); defer { interceptor.stop() }

        TraceContext.$current.withValue(recorder) {
            let base = cassette.int(seam: "clock", live: { 1000 }) // recorded seam
            let discount = cassette.int(seam: "discount", live: { 100 }) // recorded seam
            var total = Int(base - discount) // 900
            if extraSeam {
                // A new boundary the golden run never recorded. Live fallback here is 0, so behavior is
                // observably identical — but the input was NOT held identical, so it's uncertifiable.
                total += Int(cassette.int(seam: "surcharge", live: { 0 }))
            }
            center.post(
                name: Notification.Name("CheckoutCompleted"),
                object: nil,
                userInfo: ["total": total]
            )
            Haruspec.marker("checkout.completed")
        }
        return recorder.trace()
    }

    func testCleanReplayIsATrustworthyEquivalent() {
        let recording = Cassette()
        let golden = runSession(cassette: recording, extraSeam: false)
        let tape = recording.snapshot()

        let replayCassette = Cassette(replaying: tape)
        let replay = runSession(cassette: replayCassette, extraSeam: false)

        let diff = BehavioralDiff.compare(baseline: golden, candidate: replay)
        let verified = replayCassette.verify(diff)
        XCTAssertTrue(verified.isEquivalent, "same code, fully-covered replay → trustworthy EQUIVALENT")
        XCTAssertEqual(verified.coverage.fraction, 1.0)
        XCTAssertTrue(verified.coverage.gaps.isEmpty)
    }

    func testUnrecordedBoundaryDowngradesAFalseEquivalentToCannotVerify() {
        let recording = Cassette()
        let golden = runSession(cassette: recording, extraSeam: false)
        let tape = recording.snapshot()

        // The changed branch reads a surcharge seam the golden never recorded (value 0 here).
        let candidateCassette = Cassette(replaying: tape)
        let candidate = runSession(cassette: candidateCassette, extraSeam: true)

        // The trace diff is fooled — the surcharge was 0, so observable behavior looks identical.
        let diff = BehavioralDiff.compare(baseline: golden, candidate: candidate)
        XCTAssertTrue(diff.isEquivalent, "the trace alone can't see the uncontrolled surcharge read")

        // Coverage catches the unrecorded boundary and the oracle abstains rather than emit a false pass.
        let verified = candidateCassette.verify(diff)
        XCTAssertEqual(verified.verdict, .cannotVerify)
        XCTAssertEqual(verified.coverage.unrecordedReach.map(\.boundary), ["surcharge"])
        XCTAssertTrue(
            verified.report().contains("⚠️ CANNOT-VERIFY"),
            "the report abstains loudly:\n\(verified.report())"
        )
    }
}
