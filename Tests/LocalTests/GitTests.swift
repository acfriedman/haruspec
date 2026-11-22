import Foundation
@testable import HaruspecLocal
import XCTest

// Against a real scratch repository: the questions a check asks of git, and the base worktree.

final class GitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("haruspec-git-\(UUID().uuidString)/app", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "--quiet", "--initial-branch=main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try write("Sources/Cart.swift", "struct Cart {}\n")
        try git("add", ".")
        try git("commit", "--quiet", "-m", "base")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testTheMergeBaseIsWhereTheBranchLeftMain() throws {
        let base = try Git(directory: root).commit("HEAD")
        try git("checkout", "--quiet", "-b", "feature/rewards")
        try write("Sources/Cart.swift", "struct Cart { var points = 0 }\n")
        try git("commit", "--quiet", "-am", "points")

        let repository = Git(directory: root)
        XCTAssertEqual(try repository.mergeBase(with: "main"), base)
        XCTAssertEqual(try repository.currentBranch(), "feature/rewards")
        XCTAssertThrowsError(try repository.mergeBase(with: "no-such-branch"))
    }

    func testHaruspecFilesAreNeitherChangesNorUncommittedWork() throws {
        let repository = Git(directory: root)
        let base = try repository.commit("HEAD")
        try write(".haruspec/intent/main.md", "# intent\n")
        XCTAssertFalse(try repository.hasUncommittedChanges())
        XCTAssertEqual(try repository.changedFiles(since: base), [])

        try write("Sources/Receipt.swift", "struct Receipt {}\n")
        try write("Sources/Cart.swift", "struct Cart { var points = 0 }\n")
        XCTAssertTrue(try repository.hasUncommittedChanges())
        XCTAssertEqual(try repository.changedFiles(since: base), ["Sources/Cart.swift", "Sources/Receipt.swift"])
    }

    func testTheBaseCheckoutIsTheMergeBaseAndMirrorsSiblingPackages() throws {
        let base = try Git(directory: root).commit("HEAD")
        try FileManager.default.createDirectory(
            at: root.deletingLastPathComponent().appendingPathComponent("engine"),
            withIntermediateDirectories: true
        )
        try write("App.xcodeproj/project.pbxproj", "\t\trelativePath = ../engine;\n")
        try git("add", ".")
        try git("commit", "--quiet", "-m", "project")
        let withProject = try Git(directory: root).commit("HEAD")
        let directory = HaruspecDirectory(repositoryRoot: root)
        let config = LocalConfig(project: "App.xcodeproj", scheme: "App", destination: "d", testTarget: "AppTests")

        let checkout = try BaseCheckout.prepare(commit: withProject, directory: directory, config: config)
        XCTAssertEqual(try Git(directory: checkout.root).commit("HEAD"), withProject)
        let link = checkout.root.deletingLastPathComponent().appendingPathComponent("engine")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            root.deletingLastPathComponent().appendingPathComponent("engine").path
        )

        // Prepared again with the link in place: a mirrored link is never mistaken for its target.
        let again = try BaseCheckout.prepare(commit: withProject, directory: directory, config: config)
        XCTAssertEqual(again.root, checkout.root)

        // Reused for a different base: moved, not recreated.
        let moved = try BaseCheckout.prepare(commit: base, directory: directory, config: config)
        XCTAssertEqual(moved.root, checkout.root)
        XCTAssertEqual(try Git(directory: moved.root).commit("HEAD"), base)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func git(_ arguments: String...) throws {
        let result = try Shell.run(["git"] + arguments, in: root)
        XCTAssertEqual(result.status, 0, result.stderr)
    }
}
