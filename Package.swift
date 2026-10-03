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
///   HaruspecAudit       — capture-completeness auditing (resolve a verdict's origins to source).
///   HaruspecSpec    — the developer-facing `Spec { … }.verify(against:)` DSL.
///   HaruspecCoreData    — Core Data capture resources (seamed context + in-memory stack); opt-in import,
///                         carried by the umbrella (a second product would double-link the engine).
///   Haruspec            — the umbrella: one `import Haruspec` re-exports the whole consumer surface above.
///   HaruspecLocal       — the local check (`haruspec check`): drives xcodebuild to compare the merge base
///                         with the working tree, and keeps the per-branch intent doc.
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
        // The umbrella: a single `import Haruspec` surfaces macros + capture + seams + Spec DSL.
        .library(name: "Haruspec", targets: ["Haruspec"]),
        .library(name: "HaruspecCore", targets: ["HaruspecCore"]),
        .library(name: "HaruspecTrace", targets: ["HaruspecTrace"]),
        .library(name: "HaruspecMacros", targets: ["HaruspecMacros"]),
        .library(name: "HaruspecSeams", targets: ["HaruspecSeams"]),
        .library(name: "HaruspecAudit", targets: ["HaruspecAudit"]),
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
            "HaruspecMacros",
            "HaruspecSpec"
        ], path: "Sources/Demo"),

        // The MCP stdio server (`haruspec mcp`) — the tool surface other agents call. A library so the
        // protocol layer is unit-testable; the CLI subcommand is a two-line shell around it.
        .target(name: "HaruspecMCP", dependencies: [
            "HaruspecCore",
            "HaruspecSpec",
            "HaruspecLocal"
        ], path: "Sources/MCP"),
        // The local check: git, xcodebuild, and the `.haruspec/` directory, over the Spec layer's
        // continuous harness. Shared by the CLI (`haruspec check`) and the MCP server's tools.
        .target(name: "HaruspecLocal", dependencies: ["HaruspecCore", "HaruspecSpec"], path: "Sources/Local"),
        // The CLI target is `HaruspecCLI` (its product/binary is `haruspec`): a target literally
        // named `haruspec` would differ only in case from the `Haruspec` umbrella module, which collides
        // at the build-artifact layer on case-insensitive filesystems (macOS/Windows).
        // HaruspecSpec is an internal target dep here (not a product): the `report` subcommand
        // decodes and renders `SpecVerdict` artifacts, which live in the Spec module.
        .executableTarget(name: "HaruspecCLI", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecDemo",
            "HaruspecMCP",
            "HaruspecSpec",
            "HaruspecAudit",
            "HaruspecLocal"
        ], path: "Sources/CLI"),

        // Capture-completeness auditing: resolving what a verdict covered back to the sources an
        // audit has to read. Depends on Trace alone (it reads `TraceOrigin`), so the Spec layer can
        // consume its findings without a cycle.
        .target(name: "HaruspecAudit", dependencies: ["HaruspecTrace"], path: "Sources/Audit"),

        // The developer-facing Spec DSL (result-builder + Haruspec.verify). Prototype.
        .target(name: "HaruspecSpec", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecSeams",
            // The capture-completeness audit runs inside a verification (see SpecAudit.swift), so the
            // Spec layer links it; the dependency points down the stack, and Audit stays Core-free.
            "HaruspecAudit"
        ], path: "Sources/Spec"),

        // Capture resources for persistence-bearing subjects (the seamed managed-object context).
        // Depends on the Spec layer for `SeamContext`/`Variation`. NOT its own product: a second
        // product from this package links a second copy of the engine's static targets into the
        // same test bundle, and the duplicated recorder state silently empties candidate traces.
        .target(name: "HaruspecCoreData", dependencies: [
            "HaruspecSeams",
            "HaruspecSpec"
        ], path: "Sources/CoreData"),

        // The consumer umbrella. Re-export only (`@_exported import` of the five consumer modules) —
        // no logic lives here, so the dependency-free-core / SwiftSyntax-confined-to-macros layering
        // holds. Depending on HaruspecSpec here is also what makes it reachable to consumers (it is
        // deliberately not its own product; the umbrella is the single supported import).
        .target(name: "Haruspec", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecMacros",
            "HaruspecSeams",
            "HaruspecSpec",
            // Carried so a persistence-bearing spec adds `import HaruspecCoreData`, not a link step —
            // not re-exported, so the CoreData surface appears only where a spec asks for it.
            "HaruspecCoreData"
        ]),

        .testTarget(name: "HaruspecCoreTests", dependencies: ["HaruspecCore"], path: "Tests/CoreTests"),
        .testTarget(name: "HaruspecAuditTests", dependencies: [
            "HaruspecAudit",
            "HaruspecTrace"
        ], path: "Tests/AuditTests"),
        .testTarget(name: "HaruspecTraceTests", dependencies: [
            "HaruspecCore",
            "HaruspecTrace"
        ], path: "Tests/TraceTests"),
        .testTarget(name: "HaruspecSeamsTests", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecSeams",
            "LegacyObjC"
        ], path: "Tests/SeamsTests"),
        .testTarget(name: "HaruspecMacrosTests", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecMacros",
            "HaruspecSeams",
            "HaruspecSpec"
        ], path: "Tests/MacrosTests"),
        .testTarget(name: "HaruspecDemoTests", dependencies: [
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecDemo",
            "HaruspecSeams"
        ], path: "Tests/DemoTests"),
        .testTarget(name: "HaruspecSpecTests", dependencies: [
            "HaruspecSpec",
            "HaruspecCore",
            "HaruspecTrace",
            "HaruspecMacros",
            "HaruspecSeams",
            "HaruspecAudit",
            "LegacyObjC"
        ], path: "Tests/SpecTests", resources: [
            // The committed result.json the decode-compat test and the CLI smoke run render.
            .copy("Fixtures")
        ]),

        .testTarget(name: "HaruspecMCPTests", dependencies: ["HaruspecMCP", "HaruspecCore"], path: "Tests/MCPTests"),

        .testTarget(name: "HaruspecLocalTests", dependencies: [
            "HaruspecLocal",
            "HaruspecCore",
            "HaruspecSpec"
        ], path: "Tests/LocalTests"),

        .testTarget(name: "HaruspecCoreDataTests", dependencies: [
            "HaruspecCore",
            "HaruspecCoreData",
            "HaruspecSeams",
            "HaruspecSpec"
        ], path: "Tests/CoreDataTests"),

        // Consumer's-eye view: depends on ONLY the umbrella, so it fails to compile if a single
        // `import Haruspec` doesn't surface the macros, capture, seams, and Spec DSL.
        .testTarget(name: "HaruspecTests", dependencies: ["Haruspec"])
    ]
)
