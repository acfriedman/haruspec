@testable import HaruspecCore
import XCTest

/// `Comparison`'s JSON form: partial files decode to the strict defaults, round trips are exact, and
/// the retired `volatileFields` key fails loudly instead of reading as a stricter comparison.
final class ComparisonTests: XCTestCase {
    func testPartialJSONDecodesToStrictDefaults() throws {
        let comparison = try JSONDecoder().decode(Comparison.self, from: Data(#"{"numericEpsilon": 0.5}"#.utf8))
        var expected = Comparison.strict
        expected.numericEpsilon = 0.5
        XCTAssertEqual(comparison, expected)
    }

    func testJSONRoundTripIsExact() throws {
        let comparison = Comparison(
            numericEpsilon: 0.01,
            timingBudgets: ["Cart.checkout": 50],
            unorderedGroups: [["CartDidChange", "AnalyticsDidTrack"]],
            ignoredNotificationNames: ["Telemetry"],
            concurrency: .perDomain,
            spawnEdges: .advisory
        )
        let decoded = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        XCTAssertEqual(decoded, comparison)
    }

    func testRetiredVolatileFieldsKeyIsRejectedWithTheRemedy() {
        let json = #"{"volatileFields": ["orderID"]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Comparison.self, from: Data(json.utf8))) { error in
            XCTAssertTrue(
                String(describing: error).contains("inject its source"),
                "the refusal names the replacement: \(error)"
            )
        }
    }
}
