import HaruspecMacroPlugin
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import XCTest

// `@Traced` is meant to sit on code that ships, so the body it emits is guarded: DEBUG gets the
// recorder shim, release gets the method's own statements and nothing else. A debug-built test only
// ever *runs* the DEBUG branch, so these assert on the expansion itself — the release branch is
// otherwise invisible until someone ships it.

final class TracedReleaseGuardTests: XCTestCase {
    private func expand(
        _ source: String,
        attribute: String = #"@TracedMethod("Cart")"#
    ) throws -> String {
        let function = try XCTUnwrap(FunctionDeclSyntax("\(raw: source)" as DeclSyntax))
        let node = try XCTUnwrap(AttributeSyntax("\(raw: attribute)" as AttributeSyntax))
        let items = try TracedMethodMacro.expansion(
            of: node,
            providingBodyFor: function,
            in: BasicMacroExpansionContext()
        )
        return items.map(\.description).joined()
    }

    func testReleaseBranchIsTheOriginalBodyVerbatim() throws {
        let expanded = try expand(
            """
            func applyPromo(code: String) -> Bool {
                promo = code
                return true
            }
            """
        )

        let elseBranch = try XCTUnwrap(expanded.components(separatedBy: "#else").last)
            .replacingOccurrences(of: "#endif", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(elseBranch, "promo = code\n    return true")
        XCTAssertFalse(elseBranch.contains("Haruspec"), "release must carry no recorder reference")
        XCTAssertFalse(elseBranch.contains("__oracleBody"), "release must carry no instrumentation shim")
    }

    func testDebugBranchStillInstruments() throws {
        let expanded = try expand(
            """
            func applyPromo(code: String) -> Bool {
                return true
            }
            """
        )
        let debugBranch = try XCTUnwrap(expanded.components(separatedBy: "#else").first)

        XCTAssertTrue(expanded.hasPrefix("#if DEBUG"), expanded)
        XCTAssertTrue(debugBranch.contains("Cart.applyPromo"), debugBranch)
        XCTAssertTrue(debugBranch.contains("__oracleBody"), debugBranch)
    }
}
