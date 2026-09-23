import Foundation
@testable import HaruspecLocal
import XCTest

final class LocalSetupTests: XCTestCase {
    /// The launcher `init` installs is the engine repository's own script, so what a team commits
    /// is what the README documents.
    func testTheEmbeddedLauncherIsTheScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/haruspec")
        XCTAssertEqual(
            LauncherScript.text + "\n",
            try String(contentsOf: script, encoding: .utf8),
            "Scripts/haruspec and LauncherScript.swift drifted — copy the script into the string"
        )
    }

    func testInitWritesAnExecutableLauncherAndKeepsAValidConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("init-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".haruspec"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Shell.run(["git", "init", "--quiet"], in: root)
        try Data(LocalConfig.example.utf8).write(to: root.appendingPathComponent(".haruspec/config.json"))

        let first = try LocalSetup.initialize(at: root)
        XCTAssertTrue(first[0].hasPrefix("wrote .haruspec/bin/haruspec"), first[0])
        XCTAssertTrue(first[1].hasPrefix("kept .haruspec/config.json"), first[1])
        let launcher = root.appendingPathComponent(".haruspec/bin/haruspec").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher))
        XCTAssertTrue(try LocalSetup.initialize(at: root)[0].hasPrefix("kept"), "a current launcher is left alone")
    }

    func testSeveralProjectsAreRefusedWithTheFileToWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detect-\(UUID().uuidString)")
        for name in ["A.xcodeproj", "B.xcodeproj"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try LocalSetup.detectedConfig(in: root)) { error in
            XCTAssertTrue("\(error)".contains("A.xcodeproj, B.xcodeproj"), "\(error)")
        }
    }
}
