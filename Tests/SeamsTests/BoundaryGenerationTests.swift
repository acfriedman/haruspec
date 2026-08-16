@testable import HaruspecCore
@testable import HaruspecSeams
import XCTest

/// Boundary-first generation. Bugs cluster at the ends of a domain, and uniform sampling reaches an
/// end only by luck — over `.int(0 ... 20)` a given edge shows up in 95% of 64-draw runs but only 21%
/// of 5-draw runs, and a `.double` range never lands on its bounds at all. Enumerating the edges first
/// makes edge coverage a property of the design rather than of the budget: trimming a budget then drops
/// random middles and keeps the ends.
final class BoundaryGenerationTests: XCTestCase {
    /// A golden template: one track per seam, two readings each (an op applied twice).
    private func golden(_ seams: [String: Int64]) -> CassetteData {
        CassetteData(tracks: seams.mapValues { [CanonicalValue.int($0), CanonicalValue.int($0)] })
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

    // MARK: - The edges themselves

    func testAnIntegerDomainLeadsWithItsEndsThenTheirNeighbours() {
        let edges = SeamDomain.int(0 ... 20).boundaryValues

        XCTAssertEqual(edges, [.int(0), .int(20), .int(1), .int(19)])
    }

    func testZeroIsAnEdgeWhereverTheRangeStraddlesIt() {
        XCTAssertTrue(SeamDomain.int(-5 ... 5).boundaryValues.contains(.int(0)))
        XCTAssertFalse(SeamDomain.int(1 ... 5).boundaryValues.contains(.int(0)))
    }

    func testADegenerateRangeHasOneEdgeNotFour() {
        XCTAssertEqual(SeamDomain.int(3 ... 3).boundaryValues, [.int(3)])
    }

    func testADoubleRangeReachesBoundsUniformSamplingNeverHits() {
        let edges = SeamDomain.double(0 ... 1).boundaryValues

        XCTAssertEqual(edges, [.double(0), .double(1)])
    }

    func testEveryDeclaredCategoricalValueIsAnEdge() {
        // The author named each one because each is interesting — there is no interior to sample.
        let edges = SeamDomain.oneOf("SAVE10", "save10", "NOPE").boundaryValues

        XCTAssertEqual(edges, [.string("SAVE10"), .string("save10"), .string("NOPE")])
    }

    // MARK: - Magnitude ladders (the undeclared-value domain)

    func testAMagnitudeDomainLaddersEveryDecadeRolloverBothSigns() {
        let edges = SeamDomain.intMagnitudes(-10000 ... 10000).boundaryValues

        // Zero and ±1 lead (the guard-clause cluster); each rollover carries a step either side;
        // ascending, so a trimmed budget drops the large magnitudes and keeps the small.
        XCTAssertEqual(
            Array(edges.prefix(9)),
            [.int(0), .int(1), .int(-1), .int(9), .int(10), .int(11), .int(-9), .int(-10), .int(-11)]
        )
        XCTAssertTrue(edges.contains(.int(9999)) && edges.contains(.int(-9999)))
        XCTAssertTrue(edges.contains(.int(10000)) && edges.contains(.int(-10000)))
        XCTAssertFalse(edges.contains(.int(10001)), "nothing outside the declared span")
    }

    func testAnUnsignedMagnitudeDomainHasNoNegativeSide() {
        let edges = SeamDomain.intMagnitudes(0 ... 100).boundaryValues

        XCTAssertEqual(edges, [.int(0), .int(1), .int(9), .int(10), .int(11), .int(99), .int(100)])
    }

    func testADoubleMagnitudeDomainLaddersFractionalDecades() {
        let edges = SeamDomain.doubleMagnitudes(-1000 ... 1000).boundaryValues

        XCTAssertTrue(edges.contains(.double(0.001)) && edges.contains(.double(-0.001)))
        XCTAssertTrue(edges.contains(.double(1000)) && edges.contains(.double(-1000)))
        XCTAssertEqual(edges.first, .double(0))
    }

    func testMagnitudeSamplingStaysInRangeAndVisitsSmallAndLargeDecades() {
        var rng = SplitMix64(seed: 7)
        var small = 0, large = 0
        for _ in 0 ..< 200 {
            guard case let .int(value) = SeamDomain.intMagnitudes(-10000 ... 10000).sample(using: &rng) else {
                return XCTFail("an int domain samples ints")
            }
            XCTAssertTrue((-10000 ... 10000).contains(value))
            if abs(value) < 10 {
                small += 1
            }
            if abs(value) >= 1000 {
                large += 1
            }
        }
        // Log-uniform: the smalls arrive as a real share, which uniform sampling over ±10k never
        // gives them (expected ~5 of 200 uniform; a decade-first draw yields ~40).
        XCTAssertGreaterThan(small, 10, "small magnitudes must be a real share of the fill")
        XCTAssertGreaterThan(large, 10, "large magnitudes too")
    }

    // MARK: - The schedule

    func testTheFirstVariantsAreTheEdgesInOrder() {
        var generator = DomainSeamGenerator(domains: ["qty": .int(0 ... 20)], seed: 1)
        let variants = golden(["qty": 7]).generatedVariants(count: 4, using: &generator)

        XCTAssertEqual(values(variants, "qty"), [[0, 0], [20, 20], [1, 1], [19, 19]])
    }

    func testEverySeamGetsAnEdgeBeforeAnySeamGetsASecond() {
        // Round-robin, so a budget truncated to three variants still touches all three seams.
        var generator = DomainSeamGenerator(
            domains: ["a": .int(0 ... 9), "b": .int(0 ... 9), "c": .int(0 ... 9)],
            seed: 1
        )
        let variants = golden(["a": 5, "b": 5, "c": 5]).generatedVariants(count: 3, using: &generator)

        XCTAssertEqual(values(variants, "a").map(\.first), [0, 5, 5])
        XCTAssertEqual(values(variants, "b").map(\.first), [5, 0, 5])
        XCTAssertEqual(values(variants, "c").map(\.first), [5, 5, 0])
    }

    func testAScheduledVariantMovesOneSeamAndLeavesTheRestRecorded() {
        // One factor at a time: a divergence names the seam that caused it rather than arriving as a
        // vector of simultaneous extremes.
        var generator = DomainSeamGenerator(domains: ["a": .int(0 ... 9), "b": .int(0 ... 9)], seed: 1)
        let variants = golden(["a": 5, "b": 5]).generatedVariants(count: 1, using: &generator)

        XCTAssertEqual(values(variants, "a"), [[0, 0]])
        XCTAssertEqual(values(variants, "b"), [[5, 5]], "the unpinned seam keeps its recorded reading")
    }

    func testGenerationGoesRandomOnceTheScheduleIsSpent() {
        var generator = DomainSeamGenerator(domains: ["qty": .int(0 ... 1000)], seed: 9)
        let variants = golden(["qty": 7]).generatedVariants(count: 40, using: &generator)
        let tail = Set(values(variants, "qty").dropFirst(4).compactMap(\.first))

        XCTAssertGreaterThan(tail.count, 1, "the budget past the edges must still be a sample")
    }

    func testATinyBudgetStillCoversEveryEndOfEverySeam() {
        // The whole point: 4 variants over two seams used to be 4 uniform draws that might miss both
        // ends of both domains.
        var generator = DomainSeamGenerator(domains: ["a": .int(1 ... 20), "b": .int(1 ... 20)], seed: 3)
        let variants = golden(["a": 10, "b": 10]).generatedVariants(count: 4, using: &generator)

        for seam in ["a", "b"] {
            let seen = Set(values(variants, seam).compactMap(\.first))
            XCTAssertTrue(seen.contains(1), "\(seam) never reached its minimum")
            XCTAssertTrue(seen.contains(20), "\(seam) never reached its maximum")
        }
    }

    func testTheSameSeedStillReproducesTheSameVariants() {
        var first = DomainSeamGenerator(domains: ["qty": .int(0 ... 20)], seed: 5)
        var second = DomainSeamGenerator(domains: ["qty": .int(0 ... 20)], seed: 5)

        XCTAssertEqual(
            golden(["qty": 7]).generatedVariants(count: 20, using: &first),
            golden(["qty": 7]).generatedVariants(count: 20, using: &second)
        )
    }

    func testAnUndeclaredSeamStillReplaysItsRecordedValue() {
        var generator = DomainSeamGenerator(domains: ["qty": .int(0 ... 20)], seed: 1)
        let variants = golden(["qty": 7, "untouched": 42]).generatedVariants(count: 6, using: &generator)

        XCTAssertEqual(Set(values(variants, "untouched").compactMap(\.first)), [42])
    }
}
