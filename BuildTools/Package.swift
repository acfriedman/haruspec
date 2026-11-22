// swift-tools-version: 6.0
import PackageDescription

/// The tools this repository checks itself with, pinned so every clone runs the same versions, and kept
/// out of Haruspec's own manifest so nothing that depends on Haruspec builds them: SwiftLucid lints doc
/// comments, and SwiftStepdown puts each helper below the code that uses it. The pre-commit hook and CI
/// build and run both; to run one by hand from the repository's root, use
/// `swift run --quiet -c release --package-path BuildTools swiftlucid --include-tests .` or
/// `swift run --quiet -c release --package-path BuildTools swiftstepdown Sources Tests`.
let package = Package(
    name: "BuildTools",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/acfriedman/SwiftLucid", exact: "0.2.0"),
        .package(url: "https://github.com/acfriedman/SwiftStepdown", exact: "0.1.1")
    ],
    targets: [.target(name: "BuildTools", path: "", exclude: ["Package.swift"])]
)
