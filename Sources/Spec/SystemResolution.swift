import Foundation
import HaruspecSeams
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

/// A packaged default for a capture resource: linking the provider is the declaration, so a spec
/// resolves the resource with nothing authored — no `.provides`, no wiring.
///
/// Conformance is found by the same Obj-C class-list census as `SeamDouble`, so a conformer must be
/// `NSObject`-rooted. A spec-authored `.provides` for the same type always wins: the default exists
/// to remove boilerplate, never to shadow a declaration.
public protocol SeamResource: AnyObject {
    /// The resource types this provider constructs when nothing else serves them.
    static var providedResources: [Any.Type] { get }
    /// Returns a fresh resource for one capture — built per resolve, like a `.provides` maker.
    static func makeResource(_ resource: Any.Type, _ seams: SeamContext) -> Any
    /// Seam domains the resource reads, swept by default once the golden run reaches them — the
    /// packaged judgment that a resource's failure modes are behavioral surface.
    ///
    /// An authored `Seam` on the same key always wins: a spec narrows or pins a sweep, never
    /// fights it.
    static var sweptSeams: [(seam: String, domain: SeamDomain)] { get }
}

public extension SeamResource {
    /// A provider with no varied readings sweeps nothing.
    static var sweptSeams: [(seam: String, domain: SeamDomain)] {
        []
    }
}

/// Every `SeamResource` provider linked into the process; censused once, like `SeamDoubleRegistry`.
enum SeamResourceRegistry {
    static let all: [any SeamResource.Type] = {
        var count: UInt32 = 0
        guard let classes = objc_copyClassList(&count) else {
            return []
        }
        defer { free(UnsafeMutableRawPointer(classes)) }
        return UnsafeBufferPointer(start: classes, count: Int(count))
            .compactMap { $0 as? any SeamResource.Type }
    }()
}

public extension SeamContext {
    /// The synthesized double serving `boundary`, constructed and registered as an injected
    /// collaborator — exactly `context.double(TracedX.self)` with the X looked up by conformance.
    ///
    /// Derived system factories call this per collaborator parameter. Resolution order: a declared
    /// `.provides` resource, then the one conforming double, then a packaged `SeamResource`
    /// default. Zero or several candidates trap naming the fix, because a guessed collaborator
    /// would be a silent wiring change.
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
        // No double either: a packaged default may serve the type (`SeamResource`), below every
        // authored route so it can only ever fill silence.
        if candidates.isEmpty {
            let defaults = SeamResourceRegistry.all.filter { provider in
                provider.providedResources.contains { ObjectIdentifier($0) == key }
            }
            if !defaults.isEmpty {
                guard defaults.count == 1 else {
                    preconditionFailure(
                        "\(defaults.count) packaged defaults provide \(boundary): "
                            + defaults.map { "\($0)" }.sorted().joined(separator: ", ")
                            + " — pick one explicitly: .provides(\(boundary).self) { context in … }"
                    )
                }
                guard let typed = defaults[0].makeResource(boundary, self) as? P else {
                    preconditionFailure(
                        "\(defaults[0]) declares it provides \(boundary) but built a value that is not one — file a bug"
                    )
                }
                return typed
            }
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

extension Spec {
    /// The packaged sweeps this run earns: every linked `SeamResource`'s declared seams, filtered
    /// to keys the golden actually read and nothing authored.
    ///
    /// - Precondition: Two providers must not declare the same seam key; packaged keys are
    ///   type-scoped, so a collision is two packages claiming one identity.
    ///
    /// Reach is the evidence the resource is in play, so a spec that never touches it buys no
    /// variants for it.
    ///
    /// Callers merge the result fill-if-vacant beside `seamDomains` (the filter here already
    /// excludes declared keys, so plain union is that merge): the exploration plan and the replay's
    /// schedule recompute both apply it against their own golden, which is what keeps a recorded
    /// plan and a live verify reading one surface.
    func resourceSweeps(reaching reached: some Collection<String>) -> [String: SeamDomain] {
        let reached = Set(reached)
        var sweeps: [String: SeamDomain] = [:]
        for provider in SeamResourceRegistry.all {
            for (seam, domain) in provider.sweptSeams
                where reached.contains(seam) && seamDomains[seam] == nil && !argumentSeams.contains(seam) {
                precondition(
                    sweeps[seam] == nil,
                    "two packaged providers sweep \(seam) — a seam key names one reading; rescope one provider's key"
                )
                sweeps[seam] = domain
            }
        }
        return sweeps
    }
}
