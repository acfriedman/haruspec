// Haruspec — the single umbrella import for the consumer-facing surface.
//
// A downstream app writes one line:
//
//     import Haruspec
//
// and gets the whole engine: the `@Traced` / `@Timed` / `@Seamed` macros; runtime capture
// (`TraceRecorder`, `NotificationInterceptor` / `KVOInterceptor`, the `Haruspec.marker` / `Haruspec.interval`
// signposts); the record-once/replay-into-both seam harness (`Cassette` + the injected value seams);
// and the `Spec { … }.verify(against:)` DSL — no more juggling HaruspecCore + HaruspecTrace +
// HaruspecMacros + HaruspecSeams + HaruspecSpec.
//
// This target is re-export only: it holds no logic, so the package's "engine first, dependency-free
// core; SwiftSyntax confined to the macro path" layering is untouched. SwiftSyntax stays a host-side
// compiler plugin behind HaruspecMacros and never enters a consumer's own link.
//
// Naming: this module is deliberately named `Haruspec` even though HaruspecTrace already vends a
// `public enum Haruspec` (the `Haruspec.marker` / `.interval` / `.simulateCost` signposts). A module name
// and a type name may coexist in Swift — unqualified lookup resolves `Haruspec.marker(...)` to the enum,
// not the module — so the ergonomic `import Haruspec` UX is kept without ambiguity. See `HaruspecTests`,
// which references both `Haruspec.marker(...)` and the `Spec` types under a lone `import Haruspec`.

@_exported import HaruspecCore
@_exported import HaruspecMacros
@_exported import HaruspecSeams
@_exported import HaruspecSpec
@_exported import HaruspecTrace
