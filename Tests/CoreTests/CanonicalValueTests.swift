@testable import HaruspecCore
import XCTest

final class CanonicalValueTests: XCTestCase {
    func testCanonicalStringSortsObjectKeys() {
        let original: CanonicalValue = ["b": 2, "a": 1, "c": 3]
        let reordered: CanonicalValue = ["c": 3, "a": 1, "b": 2]
        // Same structure, different insertion order → identical canonical text.
        XCTAssertEqual(original.canonicalString, reordered.canonicalString)
        XCTAssertEqual(original.canonicalString, "{\"a\":1,\"b\":2,\"c\":3}")
    }

    func testJSONRoundTrip() throws {
        let value: CanonicalValue = [
            "n": .null,
            "flag": true,
            "count": 7,
            "ratio": 1.5,
            "name": "cart",
            "tags": ["a", "b"],
            "nested": ["x": 1]
        ]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(CanonicalValue.self, from: data)
        XCTAssertEqual(value, decoded)
    }

    func testLiteralsProduceExpectedCases() {
        XCTAssertEqual(CanonicalValue(integerLiteral: 3), .int(3))
        XCTAssertEqual(CanonicalValue(booleanLiteral: true), .bool(true))
        XCTAssertEqual(CanonicalValue(stringLiteral: "x"), .string("x"))
        XCTAssertEqual(nil as CanonicalValue, .null)
    }
}
