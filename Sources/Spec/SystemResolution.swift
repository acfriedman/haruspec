import Foundation
import HaruspecTrace
import ObjectiveC

// Injected doubles are the default, so the wiring that hands them in should not need authoring.
// `context.resolve(InventoryReserving.self)` finds the one synthesized double serving that boundary —
// the pasted `@TracedDouble` protocol *refines* the boundary, so conformance IS the declaration and
// there is no second registry to keep in sync. Anything unresolvable traps with the preferred fix
// spelled out: the trap message is the teaching surface for the boilerplate it replaced.

/// Every `@TracedDouble`-synthesized double linked into the process. Doubles are `NSObject`-rooted
/// (they back Obj-C injection points), so the Obj-C class list is a complete census; the sweep runs
/// once and only when a derivation actually resolves.
enum SeamDoubleRegistry {
    static let all: [any SeamDouble.Type] = {
        var count: UInt32 = 0
        guard let classes = objc_copyClassList(&count) else {
            return []
        }
        defer { free(UnsafeMutableRawPointer(classes)) }
        return UnsafeBufferPointer(start: classes, count: Int(count))
            .compactMap { $0 as? any SeamDouble.Type }
    }()
}

public extension SeamContext {
    /// The synthesized double serving `boundary`, constructed and registered as an injected
    /// collaborator — exactly `context.double(TracedX.self)` with the X looked up by conformance.
    ///
    /// Derived system factories call this per collaborator parameter. Zero or several candidates
    /// trap naming the fix, because a guessed collaborator would be a silent wiring change.
    func resolve<P>(_ boundary: P.Type) -> P {
        let key = ObjectIdentifier(boundary)
        // A declared capture resource wins: it is spec-authored, per-capture, and observed through
        // the subject's own surface rather than recorded at a boundary.
        if let make = resourceMakers[key] {
            guard let resource = make(self) as? P else {
                preconditionFailure(".provides(\(boundary).self) returned a value that is not a \(boundary)")
            }
            return resource
        }
        // Otherwise matched by type identity against what each double declares it serves — a generic
        // metatype-conformance cast (`is P.Type`) does not consult protocol conformances, so the
        // declaration route is also the only honest one.
        let candidates = SeamDoubleRegistry.all.filter { double in
            double.servedBoundaries.contains { ObjectIdentifier($0) == key }
        }
        guard candidates.count == 1 else {
            preconditionFailure(Self.unresolvable(boundary, candidates: candidates))
        }
        let instance = candidates[0].init(self)
        TraceOrigins.collector?.noteInjected(label: instance.traceLabel)
        guard let typed = instance as? P else {
            preconditionFailure(
                "\(type(of: instance)) conforms to \(boundary) as a type but not as a value — file a bug"
            )
        }
        return typed
    }

    private static func unresolvable(_ boundary: (some Any).Type, candidates: [any SeamDouble.Type]) -> String {
        guard candidates.isEmpty else {
            return "\(candidates.count) doubles serve \(boundary): "
                + candidates.map { "\($0)" }.sorted().joined(separator: ", ")
                + " — resolution must be unambiguous. Author the system: "
                + ".system { context in … context.double(\(candidates.map { "\($0)" }.sorted()[0]).self) … }"
        }
        return "nothing serves \(boundary) — declare it: paste its protocol under "
            + "@TracedDouble(label: …) refining \(boundary) (a recorded collaborator), provide it "
            + "as a capture resource: .provides(\(boundary).self) { context in … } (isolated "
            + "infrastructure, observed through the subject's reads), or author the wiring: "
            + ".system { context in … }"
    }
}
