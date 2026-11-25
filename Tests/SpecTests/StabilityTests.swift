import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// The stability layer: `verify(replaying:)` repeats the whole replay and requires every pass to agree
// on verdict + divergence inventory. These tests pin the two flapping classes a deployed gate must
// never present as a plain color — the always-different axis (a new counterexample every run, the
// shape the parallel subject had before `.perDomain`) and the genuine coin flip — plus the stable
// paths, where repetition is a quiet "N/N identical" line and the verdict is untouched.

/// Per-process nondeterminism that survives identical replay inputs — the thing a seam would have
/// captured and didn't. Deliberately NOT a seam: modeling the unmodeled axis is the subject of test.
private final class Drift: @unchecked Sendable {
    static let shared = Drift()
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
    }
}

private protocol Totaling: AnyObject {
    func total()
}

/// Baseline: a fixed observable value — the golden is deterministic.
private final class SteadySubject: Totaling {
    private let center: NotificationCenter
    init(center: NotificationCenter) {
        self.center = center
    }

    func total() {
        center.post(name: .init("Total"), object: nil, userInfo: ["value": 42])
    }
}

/// The always-different axis: every capture observes a fresh drift reading, so every replay pass
/// diverges from the golden with a *different* value — the flapping-counterexample class.
private final class DriftingSubject: Totaling {
    private let center: NotificationCenter
    init(center: NotificationCenter) {
        self.center = center
    }

    func total() {
        center.post(name: .init("Total"), object: nil, userInfo: ["value": Drift.shared.next()])
    }
}

/// A baseline that mints its own identifier: a fresh UUID per capture, never read through a seam —
/// the uncontrolled seam a redaction rule used to hide.
private final class MintingSubject: Totaling {
    private let center: NotificationCenter
    init(center: NotificationCenter) {
        self.center = center
    }

    func total() {
        center.post(name: .init("Total"), object: nil, userInfo: ["value": 42, "orderID": UUID().uuidString])
    }
}

/// The genuine coin flip: agrees with the baseline on every second capture, diverges otherwise —
/// a gate without repetition reports whichever color this pass happened to land.
private final class FlippingSubject: Totaling {
    private let center: NotificationCenter
    init(center: NotificationCenter) {
        self.center = center
    }

    func total() {
        center.post(name: .init("Total"), object: nil, userInfo: ["value": Drift.shared.next() % 2 == 0 ? 42 : 43])
    }
}

final class StabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Drift.shared.reset()
    }

    private func steadyPlan() async -> SpecPlan {
        await spec { SteadySubject(center: $0.notifications) }.record()
    }

    /// Returns a spec of one probe and no exploration: each replay pass is exactly one capture, so the
    /// drift counter maps 1:1 onto passes and the expected outcome grouping is exact.
    ///
    /// - Parameter system: Builds the baseline subject from a seam context.
    /// - Returns: The `stability.subject` spec, baselined on `system`.
    private func spec(system: @escaping (SeamContext) -> Totaling) -> BaselinedSpec<Totaling> {
        Spec<Totaling>("stability.subject")
            .operations {
                Op("total") { subject, _ in subject.total() }
            }
            .baselined(on: system)
    }

    // MARK: - The two flapping classes read UNSTABLE

    func testAlwaysDifferentAxisIsUnstableEveryTime() async {
        let plan = await steadyPlan()
        for _ in 0 ..< 20 {
            let verdict = await spec { DriftingSubject(center: $0.notifications) }.verify(replaying: plan)
            XCTAssertEqual(
                verdict.verdict,
                .unstable,
                "a subject that diverges differently every pass must read UNSTABLE, never a plain red"
            )
        }
    }

    func testAlwaysDifferentAxisCarriesOnePassPerOutcome() async {
        let plan = await steadyPlan()
        let verdict = await spec { DriftingSubject(center: $0.notifications) }.verify(replaying: plan)

        XCTAssertEqual(verdict.stability.replays, Stability.defaultReplays)
        XCTAssertEqual(
            verdict.stability.outcomes.count,
            Stability.defaultReplays,
            "every pass saw a different value, so every pass is its own outcome — that delta is the finding"
        )
        XCTAssertEqual(verdict.stability.outcomes.map(\.runs), [[1], [2], [3]])
        XCTAssertEqual(
            verdict.result.verdict,
            .diverged,
            "run 1's underlying verdict is kept for forensics; only the resolved verdict flips"
        )
    }

    func testCoinFlipIsUnstableNotAFlappingColor() async {
        let plan = await steadyPlan()
        let verdict = await spec { FlippingSubject(center: $0.notifications) }.verify(replaying: plan)

        XCTAssertEqual(verdict.verdict, .unstable)
        // Drift 1,2,3 → diverged, equivalent, diverged: the disagreement pairs a red with a GREEN —
        // without repetition this exact plan would have gated (or passed) on a coin flip.
        XCTAssertEqual(verdict.stability.outcomes.count, 2)
        XCTAssertEqual(verdict.stability.outcomes.map(\.runs), [[1, 3], [2]])
        XCTAssertEqual(verdict.stability.outcomes.map(\.verdict), [.diverged, .equivalent])
        XCTAssertTrue(
            verdict.stability.outcomes[1].inventory.isEmpty,
            "the equivalent pass contributes an empty inventory — 'no divergences' is an outcome too"
        )
    }

    // MARK: - Stable paths are untouched, and say so

    func testStableEquivalentKeepsItsVerdictAndReportsTheReproduction() async {
        let plan = await steadyPlan()
        let verdict = await spec { SteadySubject(center: $0.notifications) }.verify(replaying: plan)

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertTrue(verdict.stability.isStable)
        XCTAssertEqual(verdict.stability.replays, Stability.defaultReplays)
        XCTAssertTrue(
            verdict.report().contains("stability: 3/3 identical replays"),
            "a measured, reproduced verdict says so:\n\(verdict.report())"
        )
    }

    func testStableDivergenceStaysRedNotUnstable() async {
        let plan = await steadyPlan()
        // A deterministic wrong value: every pass diverges with the same inventory.
        final class WrongSubject: Totaling {
            private let center: NotificationCenter
            init(center: NotificationCenter) {
                self.center = center
            }

            func total() {
                center.post(name: .init("Total"), object: nil, userInfo: ["value": 41])
            }
        }
        let verdict = await spec { WrongSubject(center: $0.notifications) }.verify(replaying: plan)

        XCTAssertEqual(verdict.verdict, .diverged, "a reproducible red is a red — stability never softens it")
        XCTAssertTrue(verdict.stability.isStable)
    }

    func testSinglePassMakesNoStabilityClaim() async {
        let plan = await steadyPlan()
        let verdict = await spec { SteadySubject(center: $0.notifications) }
            .verify(replaying: plan, replays: 1)

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertEqual(verdict.stability.replays, 1)
        XCTAssertFalse(
            verdict.report().contains("stability:"),
            "one pass can't disagree with itself — the report must not claim a reproduction"
        )
    }

    // MARK: - The delta is rendered and survives the artifact

    func testUnstableReportRendersTheRunToRunDelta() async {
        let plan = await steadyPlan()
        let verdict = await spec { FlippingSubject(center: $0.notifications) }.verify(replaying: plan)

        let report = verdict.report()
        XCTAssertTrue(report.contains("🌀 UNSTABLE"), report)
        XCTAssertTrue(report.contains("2 distinct outcomes across 3 replays"), report)
        XCTAssertTrue(report.contains("runs 1,3 → diverged"), report)
        XCTAssertTrue(report.contains("run 2 → equivalent"), report)
        XCTAssertTrue(report.contains("unmodeled"), report)

        let markdown = verdict.markdownReport()
        XCTAssertTrue(markdown.contains("UNSTABLE"), markdown)
        XCTAssertTrue(markdown.contains("this check does not pass"), markdown)
    }

    func testUnstableVerdictRoundTripsThroughTheArtifact() async throws {
        let plan = await steadyPlan()
        let verdict = await spec { FlippingSubject(center: $0.notifications) }.verify(replaying: plan)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unstable-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try verdict.write(to: url)
        let reloaded = try SpecVerdict(contentsOf: url)

        XCTAssertEqual(reloaded.verdict, .unstable)
        XCTAssertEqual(reloaded.stability, verdict.stability)
    }

    // MARK: - Uncontrolled seams are named

    func testUnstableReplayNamesTheVaryingField() async {
        let plan = await steadyPlan()
        let verdict = await spec { DriftingSubject(center: $0.notifications) }.verify(replaying: plan)

        XCTAssertEqual(
            verdict.stability.uncontrolledSeams,
            [UncontrolledSeam(label: "Total", field: "value", shape: "int")],
            "the field whose value differed between passes is the unmodeled axis, named"
        )
        XCTAssertTrue(verdict.report().contains("uncontrolled seams"), verdict.report())
    }

    func testStableRedNamesNoSeam() async {
        let plan = await steadyPlan()
        final class WrongSubject: Totaling {
            private let center: NotificationCenter
            init(center: NotificationCenter) {
                self.center = center
            }

            func total() {
                center.post(name: .init("Total"), object: nil, userInfo: ["value": 41])
            }
        }
        let verdict = await spec { WrongSubject(center: $0.notifications) }.verify(replaying: plan)

        XCTAssertNil(verdict.stability.uncontrolledSeams, "a mismatch every pass agrees on is a finding, not a seam")
    }

    // MARK: - The live differential checks the baseline against itself on a red

    func testLiveBaselineThatMintsItsOwnIdentifierIsUnstable() async {
        let verdict = await spec { MintingSubject(center: $0.notifications) }
            .verify(candidate: { MintingSubject(center: $0.notifications) })

        XCTAssertEqual(
            verdict.verdict,
            .unstable,
            "a baseline that cannot reproduce itself makes the red noise, not a finding about the candidate"
        )
        XCTAssertEqual(
            verdict.stability.uncontrolledSeams,
            [UncontrolledSeam(label: "Total", field: "orderID", shape: "UUID")]
        )
        let report = verdict.report()
        XCTAssertTrue(report.contains("baseline disagreed with itself"), report)
        XCTAssertTrue(report.contains("Total.orderID (UUID)"), report)
        XCTAssertTrue(report.contains("`() -> UUID`"), report)
        XCTAssertTrue(verdict.markdownReport().contains("Uncontrolled seams"), verdict.markdownReport())
    }

    func testLiveRedFromADeterministicBaselineStaysRed() async {
        let verdict = await spec { SteadySubject(center: $0.notifications) }
            .verify(candidate: { DriftingSubject(center: $0.notifications) })

        XCTAssertEqual(
            verdict.verdict,
            .diverged,
            "nondeterminism the candidate introduced is the candidate's divergence"
        )
        XCTAssertEqual(verdict.stability.baselineSelfCheck, [])
        XCTAssertTrue(
            verdict.report().contains("the baseline reproduced itself on the failing input"),
            verdict.report()
        )
    }

    func testLiveGreenRunsNoSelfCheck() async {
        let verdict = await spec { SteadySubject(center: $0.notifications) }
            .verify(candidate: { SteadySubject(center: $0.notifications) })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertNil(verdict.stability.baselineSelfCheck)
    }
}
