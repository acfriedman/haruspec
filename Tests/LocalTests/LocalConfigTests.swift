import Foundation
@testable import HaruspecLocal
import HaruspecSpec
import XCTest

final class LocalConfigTests: XCTestCase {
    private let required = #""project":"A.xcodeproj","scheme":"A","destination":"d","testTarget":"T""#

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

    private func load(_ json: String) throws -> LocalConfig {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        return try LocalConfig.load(from: url)
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

    func testATestRunReusesTheBuildAndRunsOnlyItsSuite() throws {
        var test = run(.replay)
        test.only = ["AppTests/CartContinuousTests"]
        let arguments = test.arguments
        XCTAssertEqual(Array(arguments.prefix(2)), ["xcodebuild", "test-without-building"])
        XCTAssertTrue(arguments.contains("-only-testing:AppTests/CartContinuousTests"))
        XCTAssertFalse(arguments.contains("-only-testing:AppTests"), "the suite, not the whole target")
        XCTAssertFalse(arguments.contains("-sdk"), "-sdk breaks macro expansion; the destination selects the platform")
        XCTAssertEqual(try arguments[XCTUnwrap(arguments.firstIndex(of: "-project")) + 1], "/repo/App.xcodeproj")
    }

    func testWithoutASuiteTheWholeTargetRuns() {
        XCTAssertTrue(run(.replay).arguments.contains("-only-testing:AppTests"))
    }

    func testABuildSelectsNoTestsAndCarriesNoHaruspecEnvironment() {
        var build = XcodeTestRun(
            checkout: URL(fileURLWithPath: "/repo"),
            config: config,
            action: .buildForTesting,
            derivedData: URL(fileURLWithPath: "/cache/derived/base")
        )
        build.coverage = true
        XCTAssertEqual(build.arguments[1], "build-for-testing")
        XCTAssertFalse(build.arguments.contains { $0.hasPrefix("-only-testing") })
        XCTAssertTrue(build.arguments.contains("-enableCodeCoverage"))
        XCTAssertNil(build.environment(from: ["TEST_RUNNER_HARUSPEC_MODE": "replay"])["TEST_RUNNER_HARUSPEC_MODE"])
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

    private func run(_ mode: ContinuousMode, intent: URL? = nil) -> XcodeTestRun {
        var run = XcodeTestRun(
            checkout: URL(fileURLWithPath: "/repo"),
            config: config,
            action: .test(mode),
            derivedData: URL(fileURLWithPath: "/cache/derived/head")
        )
        run.plan = URL(fileURLWithPath: "/cache/cart.plan.json.gz")
        run.results = mode == .record ? nil : URL(fileURLWithPath: "/run/results/cart")
        run.intent = intent
        run.resultBundle = URL(fileURLWithPath: "/run/bundles/cart.xcresult")
        return run
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

final class RecordedCoverageTests: XCTestCase {
    /// Launching the app runs a spec's subject file too; only lines run beyond that are the spec's.
    func testAFileOnlyTheLaunchRanIsNotTheSpecs() {
        let startup: RecordedCoverage.LineCounts = ["Cart.m": [10: 1, 11: 1], "AppDelegate.m": [5: 1]]
        let recording: RecordedCoverage.LineCounts = [
            "Cart.m": [10: 1, 11: 1],
            "AppDelegate.m": [5: 1],
            "Store.m": [3: 7]
        ]
        XCTAssertEqual(RecordedCoverage.ownFiles(recording, beyond: startup), ["Store.m"])
    }

    func testALineRunMoreOftenThanAtLaunchMakesTheFileTheSpecs() {
        let startup: RecordedCoverage.LineCounts = ["Cart.m": [10: 1]]
        XCTAssertEqual(RecordedCoverage.ownFiles(["Cart.m": [10: 2]], beyond: startup), ["Cart.m"])
        XCTAssertEqual(RecordedCoverage.ownFiles(["Cart.m": [10: 1, 40: 1]], beyond: startup), ["Cart.m"])
    }

    func testWithoutAStartupMeasurementEveryExecutedFileCounts() {
        XCTAssertEqual(RecordedCoverage.ownFiles(["A.m": [1: 1], "B.swift": [2: 1]], beyond: nil), ["A.m", "B.swift"])
    }

    func testAChangedHeaderStandsForItsImplementation() {
        let expanded = RecordedCoverage.expandingHeaders(["Cart/CartManager.h", "README.md"])
        XCTAssertTrue(expanded.contains("Cart/CartManager.m"))
        XCTAssertTrue(expanded.contains("README.md"))
    }
}
