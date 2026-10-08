@testable import HaruspecCore
import XCTest

/// `CanonicalValue.shape`: how an uncontrolled seam is described without its value. The format of a
/// string is part of its shape, because a reader picks the injection by it.
final class CanonicalValueShapeTests: XCTestCase {
    func testIdentifiersAreNamedByCase() {
        let fresh = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        XCTAssertEqual(CanonicalValue.string(fresh).shape, "UUID")
        XCTAssertEqual(CanonicalValue.string(fresh.lowercased()).shape, "uuid")
        XCTAssertEqual(CanonicalValue.string("3f2504e0-4F89-41D3-9A0C-0305E82C3301").shape, "mixed-case uuid")
    }

    func testTimestampsAreNamedByPrecision() {
        XCTAssertEqual(CanonicalValue.string("2026-10-03T12:00:00Z").shape, "ISO 8601 timestamp")
        XCTAssertEqual(
            CanonicalValue.string("2026-10-03T12:00:00.250+02:00").shape,
            "ISO 8601 timestamp, fractional seconds"
        )
    }

    func testOtherValuesAreNamedByKind() {
        XCTAssertEqual(CanonicalValue.string("").shape, "empty string")
        XCTAssertEqual(CanonicalValue.string("SKU-7").shape, "string")
        XCTAssertEqual(CanonicalValue.int(7).shape, "int")
        XCTAssertEqual(CanonicalValue.double(7.5).shape, "double")
    }
}
