import HaruspecAudit
import HaruspecTrace
import XCTest

// Resolving a declaration to source. The cases that matter are the ones a filename guess gets wrong:
// a category in a file named after nothing, an Objective-C++ implementation, a prefix collision — and
// above all the empty result, which must stay a blind spot rather than becoming a clean read.

final class SourceResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolve(_ origin: TraceOrigin) -> SourceResolution {
        SourceResolver(root: root).resolve([origin])[0]
    }

    // MARK: - Obj-C: find the declaration, not a filename

    func testFindsAnImplementationAndEveryCategoryOfIt() throws {
        try write("@implementation CartManager\n@end\n", to: "App/CartManager.m")
        try write("@implementation CartManager (Promo)\n@end\n", to: "App/Promo/Discounts.m")

        let resolution = resolve(TraceOrigin(label: "Cart", symbol: "CartManager"))

        XCTAssertEqual(resolution.files, ["App/CartManager.m", "App/Promo/Discounts.m"])
        XCTAssertTrue(resolution.isResolved)
    }

    func testFindsAnObjectiveCPlusPlusImplementation() throws {
        try write("@implementation Renderer\n@end\n", to: "App/Renderer.mm")

        XCTAssertEqual(resolve(TraceOrigin(label: "R", symbol: "Renderer")).files, ["App/Renderer.mm"])
    }

    /// A prefix is not a match — `CartManagerV2` is a different class with different behavior.
    func testDoesNotMatchAPrefixOfTheClassName() throws {
        try write("@implementation CartManagerV2\n@end\n", to: "App/CartManagerV2.m")

        XCTAssertFalse(resolve(TraceOrigin(label: "Cart", symbol: "CartManager")).isResolved)
    }

    /// The name has to head a declaration. A mention in a comment or a string is not source to audit.
    func testIgnoresMentionsThatAreNotDeclarations() throws {
        try write("// @implementation CartManager lives elsewhere\n", to: "App/Notes.m")

        XCTAssertFalse(resolve(TraceOrigin(label: "Cart", symbol: "CartManager")).isResolved)
    }

    // MARK: - The empty result is the whole safety property

    func testAnUnfindableClassStaysABlindSpotRatherThanACleanRead() throws {
        try write("@implementation Unrelated\n@end\n", to: "App/Unrelated.m")

        let resolution = resolve(TraceOrigin(label: "Vendor", symbol: "VendorSDKClient"))

        XCTAssertFalse(resolution.isResolved, "a binary framework and a typo must land the same way")
        XCTAssertEqual(resolution.files, [])
        XCTAssertEqual(resolution.unresolvedDescription, "VendorSDKClient (no source found)")
    }

    func testBuildProductsAreNotSource() throws {
        try write("@implementation CartManager\n@end\n", to: ".build/checkouts/stale/CartManager.m")

        XCTAssertFalse(
            resolve(TraceOrigin(label: "Cart", symbol: "CartManager")).isResolved,
            "a stale copy nobody compiles must not answer for the class"
        )
    }

    // MARK: - Swift: the stamped fileID, and the wrapped-Swift-class fallback

    func testResolvesAStampedFileID() throws {
        try write("final class SwiftCartActor {}\n", to: "LegacyApp/Cart/SwiftCartActor.swift")

        let origin = TraceOrigin(
            label: "Cart",
            symbol: "SwiftCartActor",
            source: "LegacyApp/SwiftCartActor.swift"
        )

        XCTAssertEqual(resolve(origin).files, ["LegacyApp/Cart/SwiftCartActor.swift"])
    }

    /// Same file name in two modules: the fileID's module component breaks the tie.
    func testAFileIDPrefersItsOwnModuleWhenNamesCollide() throws {
        try write("final class Cart {}\n", to: "LegacyApp/Cart.swift")
        try write("final class Cart {}\n", to: "Tests/Cart.swift")

        let origin = TraceOrigin(label: "Cart", symbol: "Cart", source: "Tests/Cart.swift")

        XCTAssertEqual(resolve(origin).files, ["Tests/Cart.swift"])
    }

    /// An unbroken tie keeps both: auditing one file too many is harmless, missing the real one is not.
    func testAnUnresolvableCollisionKeepsEveryCandidate() throws {
        try write("final class Cart {}\n", to: "A/Cart.swift")
        try write("final class Cart {}\n", to: "B/Cart.swift")

        let origin = TraceOrigin(label: "Cart", symbol: "Cart", source: "Elsewhere/Cart.swift")

        XCTAssertEqual(resolve(origin).files, ["A/Cart.swift", "B/Cart.swift"])
    }

    /// A forwarder can wrap a Swift `@objc` class, which declares no `@implementation` — abstaining
    /// there would name a blind spot with the source sitting in the tree.
    func testFallsBackToASwiftDeclarationForAWrappedSwiftClass() throws {
        try write("@objc final class Bridged: NSObject {}\n", to: "App/Bridged.swift")

        XCTAssertEqual(resolve(TraceOrigin(label: "B", symbol: "Bridged")).files, ["App/Bridged.swift"])
    }

    func testFindsAnActorDeclaration() throws {
        try write("public actor Ledger {}\n", to: "App/Ledger.swift")

        XCTAssertEqual(resolve(TraceOrigin(label: "L", symbol: "Ledger")).files, ["App/Ledger.swift"])
    }

    /// A use is not a declaration: `Ledger.self` in an expression must not answer for the type.
    func testDoesNotMatchAUseOfTheTypeName() throws {
        try write("let kind = Ledger.self\n", to: "App/Uses.swift")

        XCTAssertFalse(resolve(TraceOrigin(label: "L", symbol: "Ledger")).isResolved)
    }

    // MARK: - Batch

    func testResolvesEveryOriginInOnePassKeepingOrder() throws {
        try write("@implementation CartManager\n@end\n", to: "App/CartManager.m")
        try write("final class SwiftCart {}\n", to: "App/SwiftCart.swift")

        let origins = [
            TraceOrigin(label: "Cart", symbol: "CartManager"),
            TraceOrigin(label: "Cart", symbol: "SwiftCart", source: "App/SwiftCart.swift"),
            TraceOrigin(label: "Gone", symbol: "Missing")
        ]
        let resolutions = SourceResolver(root: root).resolve(origins)

        XCTAssertEqual(resolutions.map(\.origin), origins)
        XCTAssertEqual(resolutions.map(\.isResolved), [true, true, false])
    }
}
