import XCTest
@testable import HaruspecCore

final class EncodableBridgeTests: XCTestCase {
    struct Order: Encodable {
        let id: Int
        let sku: String
        let paid: Bool
        let ratio: Double
        let tags: [String]
    }

    func testEncodesStructIntoCanonicalObject() throws {
        let value = try CanonicalValue(encoding: Order(id: 7, sku: "COFFEE", paid: true, ratio: 1.5, tags: ["a", "b"]))
        XCTAssertEqual(value, [
            "id": 7, "sku": "COFFEE", "paid": true, "ratio": 1.5, "tags": ["a", "b"],
        ])
    }

    func testEncodesTopLevelScalars() throws {
        XCTAssertEqual(try CanonicalValue(encoding: 42), .int(42))
        XCTAssertEqual(try CanonicalValue(encoding: "hi"), .string("hi"))
        XCTAssertEqual(try CanonicalValue(encoding: true), .bool(true))
    }

    func testNonThrowingConvenienceHandlesNil() {
        let none: Int? = nil
        XCTAssertNil(CanonicalValue.encoding(none))
        XCTAssertEqual(CanonicalValue.encoding(3), .int(3))
    }
}
