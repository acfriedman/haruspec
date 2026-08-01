@testable import HaruspecCore
import XCTest

/// `VolatileField` addressing: the typed factories, scoped matching, and the JSON forms
/// (bare string ⇄ scoped object).
final class ToleranceSpecTests: XCTestCase {
    func testKeyRuleMatchesAnyLabelAndDepth() {
        let rule = VolatileField.key("orderID")
        XCTAssertTrue(rule.matches(key: "orderID", label: "checkout", path: ["orderID"]))
        XCTAssertTrue(rule.matches(key: "orderID", label: "refund", path: ["receipt", "orderID"]))
        XCTAssertFalse(rule.matches(key: "cartID", label: "checkout", path: ["cartID"]))
    }

    func testEventScopeRestrictsToOneLabel() {
        let rule = VolatileField.key("id", inEvent: "checkout")
        XCTAssertTrue(rule.matches(key: "id", label: "checkout", path: ["id"]))
        XCTAssertFalse(rule.matches(key: "id", label: "addItem", path: ["id"]))
    }

    func testPathRuleRestrictsToExactPosition() {
        let rule = VolatileField.path("receipt.issuedAt")
        XCTAssertTrue(rule.matches(key: "issuedAt", label: "any", path: ["receipt", "issuedAt"]))
        XCTAssertFalse(rule.matches(key: "issuedAt", label: "any", path: ["promotion", "issuedAt"]))
        XCTAssertFalse(rule.matches(key: "issuedAt", label: "any", path: ["issuedAt"]))
    }

    func testKeyContainingADotIsOnlyKeyAddressable() {
        // "." is the path separator, so a key literally containing one never matches as a path
        // component; `.key` still addresses it by name.
        XCTAssertFalse(VolatileField.path("receipt.issuedAt")
            .matches(key: "receipt.issuedAt", label: "any", path: ["receipt.issuedAt"]))
        XCTAssertTrue(VolatileField.key("receipt.issuedAt")
            .matches(key: "receipt.issuedAt", label: "any", path: ["receipt.issuedAt"]))
    }

    func testMalformedPathStringsAreRejectedByTheParser() {
        // The `.path` factory traps on these; the parser is the testable seam.
        for bad in ["", ".", ".receipt", "receipt.", "a..b"] {
            XCTAssertNil(VolatileField.parsePath(bad), bad)
        }
        XCTAssertEqual(VolatileField.parsePath("receipt.issuedAt"), ["receipt", "issuedAt"])
    }

    func testJSONDecodesBareStringsAndScopedObjects() throws {
        let json = """
        {"volatileFields": ["orderID",
                            {"key": "id", "label": "checkout"},
                            {"path": "receipt.issuedAt", "label": "checkout"}]}
        """
        let spec = try JSONDecoder().decode(ToleranceSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.volatileFields, [
            .key("orderID"),
            .key("id", inEvent: "checkout"),
            .path("receipt.issuedAt", inEvent: "checkout")
        ])
    }

    func testJSONRejectsMalformedRules() {
        for bad in [
            #"{"volatileFields": [{"key": "orderID", "path": "receipt"}]}"#, // both coordinates
            #"{"volatileFields": [{"label": "checkout"}]}"#, // neither coordinate
            #"{"volatileFields": [{"path": ""}]}"#, // empty path
            #"{"volatileFields": [{"path": "receipt..issuedAt"}]}"# // empty component
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(ToleranceSpec.self, from: Data(bad.utf8)),
                                 bad)
        }
    }

    func testJSONRoundTripPreservesBothForms() throws {
        let spec = ToleranceSpec(volatileFields: [.key("orderID"),
                                                  .key("id", inEvent: "checkout"),
                                                  .path("receipt.issuedAt")])
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(ToleranceSpec.self, from: data)
        XCTAssertEqual(decoded.volatileFields, spec.volatileFields)

        // The unscoped key rule encodes back to a bare string, keeping hand-written specs readable.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"orderID\""))
        XCTAssertFalse(text.contains("{\"key\":\"orderID\"}"))
    }
}
