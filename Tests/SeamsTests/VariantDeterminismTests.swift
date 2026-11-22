@testable import HaruspecCore
@testable import HaruspecSeams
import XCTest

/// A plan's variants are a function of the golden template and the seed alone. The generator draws from
/// one random stream, so it must visit seams in an order the template's storage can't move.
final class VariantDeterminismTests: XCTestCase {
    private let seams = ["Product.sku", "add.quantity", "applyPromo.code", "removeSku.sku", "zone", "tier"]

    func testVariantsDoNotDependOnTheOrderTheTemplateStoresItsSeams() {
        let tracks = Dictionary(uniqueKeysWithValues: seams.map { ($0, [CanonicalValue.int(1), .int(2), .int(3)]) })
        let domains = Dictionary(uniqueKeysWithValues: seams.map { ($0, SeamDomain.int(-10000 ... 10000)) })
        let other = reordered(tracks)

        let variants = CassetteData(tracks: tracks).generatedVariants(count: 40, varying: domains, seed: 7)
        let fromOther = CassetteData(tracks: other).generatedVariants(count: 40, varying: domains, seed: 7)

        XCTAssertEqual(variants.map(\.tracks), fromOther.map(\.tracks))
    }

    /// The same tracks, stored so that walking them visits the seams in another order: built in reverse
    /// into a much larger table.
    private func reordered(_ tracks: [String: [CanonicalValue]]) -> [String: [CanonicalValue]] {
        for capacity in [64, 128, 256, 512] {
            var copy: [String: [CanonicalValue]] = [:]
            copy.reserveCapacity(capacity)
            for seam in seams.reversed() {
                copy[seam] = tracks[seam]
            }
            if Array(copy.keys) != Array(tracks.keys) {
                return copy
            }
        }
        XCTFail("could not store the tracks in another walk order")
        return tracks
    }
}
