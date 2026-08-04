@testable import HaruspecCore
@testable import HaruspecSeams
@testable import HaruspecTrace
import XCTest

/// Per-position boundary pinning. The defect these pin: an edge was applied to a seam's whole *track*,
/// so an op applied three times took the same value at all three readings. Two things went wrong with
/// that. A basket built by one repeated `add` could never be mixed while edges were being covered — it
/// was three of the same SKU — so mixed baskets survived only in the random tail. And an edge changed
/// meaning: `quantity = 20` intended as "one line at max" said "every line at max", which can trip a
/// cart-wide cap and report a divergence that has nothing to do with the edge it aimed at.
final class PositionalBoundaryTests: XCTestCase {
    /// A golden template: one track per seam, `readings` values each (an op applied that many times).
    private func golden(_ seams: [String: Int64], readings: Int) -> CassetteData {
        CassetteData(tracks: seams.mapValues { Array(repeating: CanonicalValue.int($0), count: readings) })
    }

    private func values(_ variants: [CassetteData], _ seam: String) -> [[Int64]] {
        variants.map { variant in
            (variant.tracks[seam] ?? []).compactMap {
                if case let .int(value) = $0 {
                    value
                } else {
                    nil
                }
            }
        }
    }

    // MARK: - The schedule

    func testEachEdgeIsScheduledAcrossTheWholeTrackAndThenAtOneReading() {
        var generator = DomainSeamGenerator(
            domains: ["qty": .int(0 ... 20)],
            seed: 1,
            trackLengths: ["qty": 2]
        )
        let variants = golden(["qty": 7], readings: 2).generatedVariants(count: 8, using: &generator)

        XCTAssertEqual(
            values(variants, "qty"),
            [[0, 0], [0, 7], [20, 20], [7, 20], [1, 1], [1, 7], [19, 19], [7, 19]],
            "each edge appears twice: once as the aggregate case, once at a single reading"
        )
    }

    func testThePinnedPositionRotatesSoRepeatedEdgesSweepDifferentReadings() {
        var generator = DomainSeamGenerator(
            domains: ["qty": .int(0 ... 20)],
            seed: 1,
            trackLengths: ["qty": 3]
        )
        let variants = golden(["qty": 7], readings: 3).generatedVariants(count: 8, using: &generator)
        // The odd variants are the single-reading pins; which slot they move must not be constant.
        let moved = values(variants, "qty").enumerated().filter { $0.offset.isMultiple(of: 2) == false }
            .map { $0.element.firstIndex { $0 != 7 } }

        XCTAssertEqual(moved, [0, 1, 2, 0], "four edges over three readings cycle through every slot")
    }

    func testASeamReadOnceKeepsExactlyTheScheduleItAlwaysHad() {
        // `.at(0)` on a one-reading track is the whole-track pin again — a duplicated variant is budget
        // spent on nothing, so it is never scheduled.
        var generator = DomainSeamGenerator(
            domains: ["qty": .int(0 ... 20)],
            seed: 1,
            trackLengths: ["qty": 1]
        )
        let variants = golden(["qty": 7], readings: 1).generatedVariants(count: 4, using: &generator)

        XCTAssertEqual(values(variants, "qty"), [[0], [20], [1], [19]])
    }

    func testUnknownTrackLengthsFallBackToTheWholeTrackPass() {
        // A hand-built generator that says nothing about lengths must behave exactly as it used to.
        var generator = DomainSeamGenerator(domains: ["qty": .int(0 ... 20)], seed: 1)
        let variants = golden(["qty": 7], readings: 2).generatedVariants(count: 4, using: &generator)

        XCTAssertEqual(values(variants, "qty"), [[0, 0], [20, 20], [1, 1], [19, 19]])
    }

    // MARK: - What it buys

    func testTheEngineOverloadReadsTrackLengthsOffTheGolden() {
        // `generatedVariants(count:varying:seed:)` is the path `ExplorationPlan` drives, so the engine
        // gets per-position pinning without the caller measuring anything.
        let variants = golden(["qty": 7], readings: 2)
            .generatedVariants(count: 2, varying: ["qty": .int(0 ... 20)], seed: 1)

        XCTAssertEqual(values(variants, "qty"), [[0, 0], [0, 7]])
    }

    func testACategoricalSeamReachesAMixedTrackDuringTheBoundaryPass() {
        // The collapse this exists for: one `add` op reading a sku per occurrence. Every boundary
        // variant used to be a basket of three identical SKUs.
        let domains = ["sku": SeamDomain.oneOf("COFFEE", "MUG", "BEANS")]
        let template = CassetteData(tracks: ["sku": Array(repeating: CanonicalValue.string("COFFEE"), count: 3)])

        let variants = template.generatedVariants(count: 6, varying: domains, seed: 1)
        let mixed = variants.filter { Set(($0.tracks["sku"] ?? []).map(\.canonicalString)).count > 1 }

        XCTAssertFalse(mixed.isEmpty, "the edge pass has to reach a basket holding two different SKUs")
    }

    // MARK: - Localization

    /// Reads `qty` twice; the branches differ only when the *second* reading is extreme. The first
    /// reading is therefore irrelevant, and a counterexample that still carries it is a lead, not a
    /// reproduction.
    private func runTwoAdds(cassette: Cassette, clamp: Bool) -> Trace {
        let recorder = TraceRecorder(name: "cart", clock: ManualClock())
        let center = NotificationCenter()
        let interceptor = NotificationInterceptor(recorder: recorder, center: center, names: ["CartTotal"])
        interceptor.start(); defer { interceptor.stop() }

        TraceContext.$current.withValue(recorder) {
            let first = cassette.int(seam: "qty", live: { 1 })
            let second = cassette.int(seam: "qty", live: { 1 })
            let total = first + (clamp ? min(second, 100) : second)
            center.post(name: Notification.Name("CartTotal"), object: nil, userInfo: ["total": Int(total)])
        }
        return recorder.trace()
    }

    func testShrinkingLocalizesToTheOneReadingThatMatters() throws {
        let recording = Cassette()
        _ = runTwoAdds(cassette: recording, clamp: false)
        let property = DifferentialProperty(golden: recording.snapshot()) { cassette, branch in
            self.runTwoAdds(cassette: cassette, clamp: branch == .candidate)
        }

        let result = property.check(count: 16, varying: ["qty": .int(0 ... 500)], seed: 3)
        let counter = try XCTUnwrap(result.firstFailure)
        let track = (counter.cassette.tracks["qty"] ?? []).compactMap {
            if case let .int(value) = $0 {
                value
            } else {
                nil
            }
        }

        XCTAssertEqual(track.first, 1, "the first reading never mattered — it belongs back on golden")
        XCTAssertGreaterThan(track.last ?? 0, 100, "the second reading is what separates the branches")
    }
}
