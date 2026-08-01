@testable import HaruspecCore
import XCTest

/// The three-tier verdict lives on `VerificationResult`, which composes a pure `TraceDiff` with a
/// `Coverage` signal. These tests pin the soundness core — the `resolve` downgrade rule — against
/// hand-built diffs + coverage, no capture or replay needed. The one law under test: **never emit a
/// false EQUIVALENT**; an uncovered surface downgrades to CANNOT-VERIFY, a real divergence stands.
final class VerificationTests: XCTestCase {
    private func diff(_ verdict: TraceDiff.Verdict, _ divergences: [Divergence] = []) -> TraceDiff {
        TraceDiff(verdict: verdict, baselineName: "base", candidateName: "cand", divergences: divergences)
    }

    // Complete: both declared seams exercised cleanly, no gaps.
    private let complete = Coverage(declared: ["clock", "rng"], exercised: ["clock", "rng"], gaps: [])
    /// A live fallback (miss) on `rng` — isolation broke.
    private let missGap = Coverage(
        declared: ["clock", "rng"],
        exercised: ["clock"],
        gaps: [Coverage.Gap(boundary: "rng", ordinal: 2, reason: .unrecorded)]
    )
    /// A declared seam the replay never reached — lowers the fraction, but no live fallback.
    private let unexercised = Coverage(
        declared: ["clock", "rng"],
        exercised: ["clock"],
        gaps: [Coverage.Gap(boundary: "rng", reason: .unexercised)]
    )

    // MARK: - The resolve rule

    func testEquivalentOverCompleteCoverageStaysEquivalent() {
        let result = VerificationResult(diff: diff(.equivalent), coverage: complete)
        XCTAssertEqual(result.verdict, .equivalent)
        XCTAssertTrue(result.isEquivalent)
    }

    func testEquivalentOverUnrecordedGapDowngradesToCannotVerify() {
        let result = VerificationResult(diff: diff(.equivalent), coverage: missGap)
        XCTAssertEqual(result.verdict, .cannotVerify, "an EQUIVALENT over a live-fallback gap is untrustworthy")
        XCTAssertFalse(result.isEquivalent, "abstention is NOT a pass")
    }

    func testDivergedStandsUnderCoverageGap() {
        // A real divergence is the safe direction — coverage annotates it, never hides or softens it.
        let result = VerificationResult(diff: diff(.diverged), coverage: missGap)
        XCTAssertEqual(result.verdict, .diverged)
    }

    func testUnknownSurfaceIsNeverTrusted() {
        // No declared registry ⇒ no coverage claim ⇒ an EQUIVALENT can't be certified.
        let result = VerificationResult(diff: diff(.equivalent), coverage: Coverage())
        XCTAssertEqual(result.verdict, .cannotVerify)
    }

    func testUnexercisedGapLowersFractionButDoesNotDowngrade() {
        // v1 policy: only unrecorded reach (a live fallback) hard-triggers CANNOT-VERIFY. A declared
        // seam that simply wasn't reached lowers the reported fraction but doesn't gate.
        let result = VerificationResult(diff: diff(.equivalent), coverage: unexercised)
        XCTAssertEqual(result.verdict, .equivalent)
        XCTAssertEqual(result.coverage.fraction, 0.5)
    }

    // MARK: - Coverage arithmetic

    func testFractionAndTrust() {
        XCTAssertEqual(complete.fraction, 1.0)
        XCTAssertTrue(complete.trustsEquivalent)
        XCTAssertEqual(missGap.fraction, 0.5)
        XCTAssertFalse(missGap.trustsEquivalent)
        XCTAssertNil(Coverage().fraction, "an unknown surface has no fraction")
        XCTAssertFalse(Coverage().trustsEquivalent)
        XCTAssertEqual(missGap.unrecordedReach.count, 1)
        XCTAssertEqual(unexercised.unrecordedReach.count, 0)
    }

    // MARK: - Intent composes with coverage

    func testClassifiedReResolvesAgainstCoverage() {
        let loyalty = Divergence(
            kind: .unexpectedEvent,
            label: "Loyalty",
            baselineSeq: nil,
            candidateSeq: 0,
            detail: "new event"
        )
        let raw = VerificationResult(diff: diff(.diverged, [loyalty]), coverage: complete)
        XCTAssertEqual(raw.verdict, .diverged, "undeclared, so it gates")

        // Declaring the delta as intended clears the gate; over complete coverage the verdict is a
        // trustworthy EQUIVALENT.
        let declared = raw.classified(against: IntentSpec(expectedNewEvents: ["Loyalty"]))
        XCTAssertTrue(declared.isEquivalent)

        // But the same intent over a live-fallback gap can't be certified — coverage still downgrades.
        let overGap = VerificationResult(diff: diff(.diverged, [loyalty]), coverage: missGap)
            .classified(against: IntentSpec(expectedNewEvents: ["Loyalty"]))
        XCTAssertEqual(overGap.verdict, .cannotVerify)
    }

    // MARK: - Reporting

    func testReportRendersBannerAndCoverage() {
        let clean = VerificationResult(diff: diff(.equivalent), coverage: complete).report()
        XCTAssertTrue(clean.contains("✅ EQUIVALENT"))
        XCTAssertTrue(clean.contains("2/2 declared seams exercised (100%)"))

        let abstain = VerificationResult(diff: diff(.equivalent), coverage: missGap).report()
        XCTAssertTrue(abstain.contains("⚠️ CANNOT-VERIFY"))
        XCTAssertTrue(abstain.contains("(50%)"))
        XCTAssertTrue(abstain.contains("rng#2"), "names the unrecorded boundary")
        XCTAssertTrue(abstain.contains("abstaining:"))
    }

    func testAgentBriefRelaysAbstentionNotAPass() {
        let brief = VerificationResult(diff: diff(.equivalent), coverage: missGap).agentBrief()
        XCTAssertTrue(brief.contains("ABSTAIN"))
        XCTAssertTrue(brief.contains("4 = ABSTAIN"))
        XCTAssertTrue(brief.contains("Do NOT report it as a"))
    }

    func testJSONRoundTrips() throws {
        let original = VerificationResult(diff: diff(.equivalent), coverage: missGap)
        let data = try original.jsonData()
        let restored = try JSONDecoder().decode(VerificationResult.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.verdict, .cannotVerify, "the resolved verdict survives serialization")
    }
}
