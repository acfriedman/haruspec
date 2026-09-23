import Foundation
@testable import HaruspecLocal
import HaruspecSpec
import XCTest

final class LocalConfigTests: XCTestCase {
    private let required = #""project":"A.xcodeproj","scheme":"A","destination":"d","testTarget":"T""#

    private func load(_ json: String) throws -> LocalConfig {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        return try LocalConfig.load(from: url)
    }

    func testTheExampleLoadsWithDefaults() throws {
        let config = try load(LocalConfig.example)
        XCTAssertEqual(config.resolvedBase, "main")
        XCTAssertEqual(config.resolvedConfiguration, "Debug")
        XCTAssertNil(config.specs)
    }

    func testAnUnknownKeyIsRefusedByName() {
        XCTAssertThrowsError(try load("{\(required),\"sheme\":\"x\"}")) {
            XCTAssertTrue("\($0)".contains("\"sheme\""), "\($0)")
        }
    }

    func testProjectAndWorkspaceAreExclusive() {
        XCTAssertThrowsError(try load(#"{"scheme":"A","destination":"d","testTarget":"T"}"#))
        XCTAssertThrowsError(try load(
            #"{"project":"A.xcodeproj","workspace":"A.xcworkspace","scheme":"A","destination":"d","testTarget":"T"}"#
        ))
    }

    func testAnEmptySpecListIsRefused() {
        XCTAssertThrowsError(try load("{\(required),\"specs\":[]}"))
    }

    func testAMissingFileTeachesTheFileToWrite() {
        let url = URL(fileURLWithPath: "/nonexistent/.haruspec/config.json")
        XCTAssertThrowsError(try LocalConfig.load(from: url)) { error in
            XCTAssertEqual(error as? LocalCheckError, .missingConfig(url.path))
            XCTAssertTrue("\(error)".contains("\"testTarget\""))
        }
    }
}

final class XcodeTestRunTests: XCTestCase {
    private let config = LocalConfig(
        project: "App.xcodeproj",
        scheme: "App",
        destination: "platform=iOS Simulator,name=iPhone 17",
        testTarget: "AppTests"
    )

    private func run(_ mode: ContinuousMode, intent: URL? = nil) -> XcodeTestRun {
        XcodeTestRun(
            checkout: URL(fileURLWithPath: "/repo"),
            config: config,
            mode: mode,
            plan: URL(fileURLWithPath: "/cache/cart.plan.json.gz"),
            results: mode == .record ? nil : URL(fileURLWithPath: "/run/results/cart"),
            intent: intent,
            derivedData: URL(fileURLWithPath: "/cache/derived/head"),
            resultBundle: URL(fileURLWithPath: "/run/bundles/cart.xcresult")
        )
    }

    func testTheWholeTargetRunsAndNoSDKIsPassed() throws {
        let arguments = run(.replay).arguments
        XCTAssertEqual(Array(arguments.prefix(2)), ["xcodebuild", "test"])
        XCTAssertTrue(arguments.contains("-only-testing:AppTests"))
        XCTAssertFalse(arguments.contains("-sdk"), "-sdk breaks macro expansion; the destination selects the platform")
        XCTAssertEqual(try arguments[XCTUnwrap(arguments.firstIndex(of: "-project")) + 1], "/repo/App.xcodeproj")
    }

    func testTheEnvironmentReplacesInheritedHaruspecValues() {
        let inherited = ["PATH": "/bin", "TEST_RUNNER_HARUSPEC_INTENT_PATH": "/stale.intent.json"]
        let environment = run(.record).environment(from: inherited)

        XCTAssertEqual(environment["PATH"], "/bin")
        XCTAssertEqual(environment["TEST_RUNNER_HARUSPEC_MODE"], "record")
        XCTAssertEqual(environment["TEST_RUNNER_HARUSPEC_PLAN_PATH"], "/cache/cart.plan.json.gz")
        XCTAssertNil(environment["TEST_RUNNER_HARUSPEC_INTENT_PATH"], "a record run never carries intent")
        XCTAssertNil(environment["TEST_RUNNER_HARUSPEC_RESULTS_DIR"])
    }

    func testAReplayCarriesItsIntentAndSourceRoot() {
        let intent = URL(fileURLWithPath: "/run/intent/cart.intent.json")
        let environment = run(.replay, intent: intent).environment(from: [:])
        XCTAssertEqual(environment["TEST_RUNNER_HARUSPEC_INTENT_PATH"], "/run/intent/cart.intent.json")
        XCTAssertEqual(environment["TEST_RUNNER_HARUSPEC_RESULTS_DIR"], "/run/results/cart")
        XCTAssertEqual(environment["TEST_RUNNER_HARUSPEC_SOURCE_ROOT"], "/repo")
    }

    func testPathsResolveWithoutTouchingTheFileSystem() {
        XCTAssertEqual(BaseCheckout.lexicallyResolved("/cache/base/app", "../haruspec").path, "/cache/base/haruspec")
        XCTAssertEqual(BaseCheckout.lexicallyResolved("/cache/base/app/", "./../../x/./y").path, "/cache/x/y")
    }

    func testOutOfTreePackageReferencesAreFound() {
        let project = """
            A1 /* XCLocalSwiftPackageReference "../haruspec" */ = {
                isa = XCLocalSwiftPackageReference;
                relativePath = ../haruspec;
            };
            B2 = {
                isa = XCLocalSwiftPackageReference;
                relativePath = "../../shared/Kit";
            };
            C3 = {
                isa = XCLocalSwiftPackageReference;
                relativePath = LocalKit;
            };
        """
        XCTAssertEqual(
            BaseCheckout.outOfTreePackageReferences(inProjectFile: project),
            ["../haruspec", "../../shared/Kit"]
        )
    }
}
