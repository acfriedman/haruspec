// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

/// Haruspec — the behavioral-oracle engine.
///
/// Layering follows the "engine first, applications second" principle. Module (target) names keep the
/// `Haruspec` prefix so they can't clash in a consumer's dependency graph; the folders under Sources/
/// drop it (wired via each target's `path:`), and type names are unprefixed — the module namespaces
/// them. The only public entry point is the `Haruspec` umbrella.
///   HaruspecCore        — the evergreen behavioral-diff primitive (model + canonicalize + tolerances + diff).
///   HaruspecTrace       — the runtime capture library (recorder, interceptors, ambient TraceContext).
///   HaruspecMacros      — the `@Traced` / `@TracedMethod` declarations (opt-in zero-code method capture).
///   HaruspecMacroPlugin — the compiler-plugin implementation of those macros (the only SwiftSyntax user).
///   HaruspecSeams       — the record-once/replay-into-both seam harness (Cassette + injected value seams).
///   HaruspecScenario    — the developer-facing `Scenario { … }.verify(against:)` DSL.
///   Haruspec            — the umbrella: one `import Haruspec` re-exports the whole consumer surface above.
///   HaruspecDemo        — a sample application (a checkout module) that exercises the engine end-to-end.
///   haruspec            — a thin CLI over the engine (diff / demo / canonicalize).
///
/// The engine core (HaruspecCore, HaruspecTrace, haruspec) is dependency-free; SwiftSyntax is confined to the
/// opt-in macro path (HaruspecMacroPlugin + HaruspecMacros), pinned to a prebuilt release for fast builds.
/// The `Haruspec` umbrella is re-export only (no logic), so it preserves that layering: consumers link one
/// module; SwiftSyntax stays a host-side macro plugin and never enters the app's own link.
let package = Package(
    name: "Haruspec",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // The umbrella: a single `import Haruspec` surfaces macros + capture + seams + Scenario DSL.
        .library(name: "Haruspec", targets: ["Haruspec"]),
        .library(name: "HaruspecCore", targets: ["HaruspecCore"]),
        .library(name: "HaruspecTrace", targets: ["HaruspecTrace"]),
        .library(name: "HaruspecMacros", targets: ["HaruspecMacros"]),
        .library(name: "HaruspecSeams", targets: ["HaruspecSeams"]),
        .library(name: "HaruspecDemo", targets: ["HaruspecDemo"]),
        .executable(name: "haruspec", targets: ["HaruspecCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.1")
    ],
    targets: [
        .target(name: "HaruspecCore", path: "Sources/Core"),

        .target(name: "HaruspecTrace", dependencies: ["HaruspecCore"], path: "Sources/Trace"),
        .target(name: "HaruspecSeams", dependencies: ["HaruspecCore"], path: "Sources/Seams"),

        // A genuine Objective-C fixture (test-only, not a product): a legacy `.m`/`.h` singleton the
        // one-shot injectability bootstrap (`SeamSwizzle`) is proven against — real ObjC dispatch, no
        // `dynamic` gymnastics. See the injectability precondition in `docs/SEAMS.md`.
        .target(name: "LegacyObjC"),

        .macro(name: "HaruspecMacroPlugin", dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
        ], path: "Sources/MacroPlugin"),
        .target(name: "HaruspecMacros", dependencies: ["HaruspecMacroPlugin", "HaruspecTrace"], path: "Sources/Macros"),

        .target(name: "HaruspecDemo", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecMacros"
        ], path: "Sources/Demo"),

        // The MCP stdio server (`haruspec mcp`) — the tool surface other agents call. A library so the
        // protocol layer is unit-testable; the CLI subcommand is a two-line shell around it.
        .target(name: "HaruspecMCP", dependencies: ["HaruspecCore"], path: "Sources/MCP"),
        // The CLI target is `HaruspecCLI` (its product/binary is `haruspec`): a target literally
        // named `haruspec` would differ only in case from the `Haruspec` umbrella module, which collides
        // at the build-artifact layer on case-insensitive filesystems (macOS/Windows).
        // HaruspecScenario is an internal target dep here (not a product): the `report` subcommand
        // decodes and renders `ScenarioVerdict` artifacts, which live in the Scenario module.
        .executableTarget(name: "HaruspecCLI", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecDemo",
            "HaruspecMCP",
            "HaruspecScenario"
        ], path: "Sources/CLI"),

        // The developer-facing Scenario DSL (result-builder + Haruspec.verify). Prototype.
        .target(name: "HaruspecScenario", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecSeams"
        ], path: "Sources/Scenario"),

        // The consumer umbrella. Re-export only (`@_exported import` of the five consumer modules) —
        // no logic lives here, so the dependency-free-core / SwiftSyntax-confined-to-macros layering
        // holds. Depending on HaruspecScenario here is also what makes it reachable to consumers (it is
        // deliberately not its own product; the umbrella is the single supported import).
        .target(name: "Haruspec", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecMacros",
            "HaruspecSeams",
            "HaruspecScenario"
        ]),

        .testTarget(name: "HaruspecCoreTests", dependencies: ["HaruspecCore"], path: "Tests/CoreTests"),
        .testTarget(name: "HaruspecTraceTests", dependencies: [
            "HaruspecCore",
            "HaruspecTrace"
        ], path: "Tests/TraceTests"),
        .testTarget(name: "HaruspecSeamsTests", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecSeams",
            "HaruspecMacros",
            "LegacyObjC"
        ], path: "Tests/SeamsTests"),
        .testTarget(name: "HaruspecMacrosTests", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecMacros"
        ], path: "Tests/MacrosTests"),
        .testTarget(name: "HaruspecDemoTests", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecDemo",
            "HaruspecSeams"
        ], path: "Tests/DemoTests"),
        .testTarget(name: "HaruspecScenarioTests", dependencies: [
            "HaruspecScenario",
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecMacros",
            "HaruspecSeams",
            "LegacyObjC"
        ], path: "Tests/ScenarioTests", resources: [
            // The committed result.json the decode-compat test and the CLI smoke run render.
            .copy("Fixtures")
        ]),

        .testTarget(name: "HaruspecMCPTests", dependencies: ["HaruspecMCP", "HaruspecCore"], path: "Tests/MCPTests"),

        // Consumer's-eye view: depends on ONLY the umbrella, so it fails to compile if a single
        // `import Haruspec` doesn't surface the macros, capture, seams, and Scenario DSL.
        .testTarget(name: "HaruspecTests", dependencies: ["Haruspec"])
    ]
)
