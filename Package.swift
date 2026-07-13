// swift-tools-version: 6.0
import PackageDescription
import CompilerPluginSupport

// Oracle — the iOS Behavioral Oracle engine.
//
// Layering follows the "engine first, applications second" principle:
//   OracleCore        — the evergreen behavioral-diff primitive (model + canonicalize + tolerances + diff).
//   OracleTrace       — the runtime capture library (recorder, interceptors, ambient TraceContext).
//   OracleMacros      — the `@Traced` / `@TracedMethod` declarations (opt-in zero-code method capture).
//   OracleMacroPlugin — the compiler-plugin implementation of those macros (the only SwiftSyntax user).
//   OracleSeams       — the record-once/replay-into-both seam harness (Cassette + injected value seams).
//   OracleScenario    — the developer-facing `Scenario { … }.verify(against:)` DSL.
//   Oracle            — the umbrella: one `import Oracle` re-exports the whole consumer surface above.
//   OracleDemo        — a sample application (a checkout module) that exercises the engine end-to-end.
//   oracle            — a thin CLI over the engine (diff / demo / canonicalize).
//
// The engine core (OracleCore, OracleTrace, oracle) is dependency-free; SwiftSyntax is confined to the
// opt-in macro path (OracleMacroPlugin + OracleMacros), pinned to a prebuilt release for fast builds.
// The `Oracle` umbrella is re-export only (no logic), so it preserves that layering: consumers link one
// module; SwiftSyntax stays a host-side macro plugin and never enters the app's own link.
let package = Package(
    name: "Oracle",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // The umbrella: a single `import Oracle` surfaces macros + capture + seams + Scenario DSL.
        .library(name: "Oracle", targets: ["Oracle"]),
        .library(name: "OracleCore", targets: ["OracleCore"]),
        .library(name: "OracleTrace", targets: ["OracleTrace"]),
        .library(name: "OracleMacros", targets: ["OracleMacros"]),
        .library(name: "OracleSeams", targets: ["OracleSeams"]),
        .library(name: "OracleDemo", targets: ["OracleDemo"]),
        .executable(name: "oracle", targets: ["OracleCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.1"),
    ],
    targets: [
        .target(name: "OracleCore"),

        .target(name: "OracleTrace", dependencies: ["OracleCore"]),
        .target(name: "OracleSeams", dependencies: ["OracleCore"]),

        // A genuine Objective-C fixture (test-only, not a product): a legacy `.m`/`.h` singleton the
        // one-shot injectability bootstrap (`SeamSwizzle`) is proven against — real ObjC dispatch, no
        // `dynamic` gymnastics. See the injectability precondition in `docs/SEAMS.md`.
        .target(name: "LegacyObjC"),

        .macro(name: "OracleMacroPlugin", dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ]),
        .target(name: "OracleMacros", dependencies: ["OracleMacroPlugin", "OracleTrace"]),

        .target(name: "OracleDemo", dependencies: ["OracleCore", "OracleTrace", "OracleMacros"]),
        // The CLI target is `OracleCLI` (its product/binary is still `oracle`): a target literally
        // named `oracle` would differ only in case from the `Oracle` umbrella module, which collides
        // at the build-artifact layer on case-insensitive filesystems (macOS/Windows).
        .executableTarget(name: "OracleCLI", dependencies: ["OracleCore", "OracleTrace", "OracleDemo"]),

        // The developer-facing Scenario DSL (result-builder + Oracle.verify). Prototype.
        .target(name: "OracleScenario", dependencies: ["OracleCore", "OracleTrace", "OracleSeams"]),

        // The consumer umbrella. Re-export only (`@_exported import` of the five consumer modules) —
        // no logic lives here, so the dependency-free-core / SwiftSyntax-confined-to-macros layering
        // holds. Depending on OracleScenario here is also what makes it reachable to consumers (it is
        // deliberately not its own product; the umbrella is the single supported import).
        .target(name: "Oracle", dependencies: [
            "OracleCore", "OracleTrace", "OracleMacros", "OracleSeams", "OracleScenario",
        ]),

        .testTarget(name: "OracleCoreTests", dependencies: ["OracleCore"]),
        .testTarget(name: "OracleTraceTests", dependencies: ["OracleCore", "OracleTrace"]),
        .testTarget(name: "OracleSeamsTests", dependencies: ["OracleCore", "OracleTrace", "OracleSeams", "OracleMacros", "LegacyObjC"]),
        .testTarget(name: "OracleMacrosTests", dependencies: ["OracleCore", "OracleTrace", "OracleMacros"]),
        .testTarget(name: "OracleDemoTests", dependencies: ["OracleCore", "OracleTrace", "OracleDemo", "OracleSeams"]),
        .testTarget(name: "OracleScenarioTests", dependencies: ["OracleScenario", "OracleCore", "OracleTrace", "OracleMacros", "OracleSeams", "LegacyObjC"]),

        // Consumer's-eye view: depends on ONLY the umbrella, so it fails to compile if a single
        // `import Oracle` doesn't surface the macros, capture, seams, and Scenario DSL.
        .testTarget(name: "OracleTests", dependencies: ["Oracle"]),
    ]
)
