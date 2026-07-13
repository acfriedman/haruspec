// Oracle — the single umbrella import for the consumer-facing surface.
//
// A downstream app writes one line:
//
//     import Oracle
//
// and gets the whole engine: the `@Traced` / `@Timed` / `@Seamed` macros; runtime capture
// (`TraceRecorder`, `NotificationInterceptor` / `KVOInterceptor`, the `Oracle.marker` / `Oracle.interval`
// signposts); the record-once/replay-into-both seam harness (`Cassette` + the injected value seams);
// and the `Scenario { … }.verify(against:)` DSL — no more juggling OracleCore + OracleTrace +
// OracleMacros + OracleSeams + OracleScenario.
//
// This target is re-export only: it holds no logic, so the package's "engine first, dependency-free
// core; SwiftSyntax confined to the macro path" layering is untouched. SwiftSyntax stays a host-side
// compiler plugin behind OracleMacros and never enters a consumer's own link.
//
// Naming: this module is deliberately named `Oracle` even though OracleTrace already vends a
// `public enum Oracle` (the `Oracle.marker` / `.interval` / `.simulateCost` signposts). A module name
// and a type name may coexist in Swift — unqualified lookup resolves `Oracle.marker(...)` to the enum,
// not the module — so the ergonomic `import Oracle` UX is kept without ambiguity. See `OracleTests`,
// which references both `Oracle.marker(...)` and the `Scenario` types under a lone `import Oracle`.

@_exported import OracleCore
@_exported import OracleTrace
@_exported import OracleMacros
@_exported import OracleSeams
@_exported import OracleScenario
