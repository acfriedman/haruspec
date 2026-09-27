import HaruspecSpec
import XCTest

// A suite's identity is what `xcodebuild -only-testing:` selects it by, after the test target.

final class ContinuousSuiteTests: XCTestCase {
    func testASuiteIsNamedWithoutItsModule() {
        XCTAssertEqual(ContinuousSuite(ContinuousSuiteTests.self)?.path, "ContinuousSuiteTests")
    }

    func testANestedSuiteIsSelectedByItsPath() {
        XCTAssertEqual(ContinuousSuite(Outer.Inner.self)?.path, "Outer/Inner")
    }

    func testAPrivateTypeHasNoSelectableName() {
        XCTAssertNil(ContinuousSuite(Hidden.self))
    }

    private struct Hidden {}
}

enum Outer {
    struct Inner {}
}
