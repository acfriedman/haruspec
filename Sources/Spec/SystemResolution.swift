import Foundation
import HaruspecSeams
import HaruspecTrace
import MachO
import ObjectiveC

// Injected doubles are the default, so the wiring that hands them in should not need authoring.
// `context.resolve(InventoryReserving.self)` finds the one synthesized double serving that boundary —
// the stamped protocol *refines* the boundary, so conformance IS the declaration and
// there is no second registry to keep in sync. Anything unresolvable traps with the preferred fix
// spelled out: the trap message is the teaching surface for the boilerplate it replaced.

/// The Obj-C classes from the process's own images: the app, its test bundle, and the packages they
/// link. The OS frameworks hold most of a process's classes and none of Haruspec's, so skipping them
/// keeps the census in the hundreds rather than the tens of thousands.
///
/// Censused once and shared by every registry below. The cost is the conformance cast each class
/// takes, so the class count is what the census pays for.
enum LinkedClasses {
    static let all: [AnyClass] = {
        var classes: [AnyClass] = []
        for index in 0 ..< _dyld_image_count() {
            guard let image = _dyld_get_image_name(index), !isSystemImage(String(cString: image)) else {
                continue
            }
            var count: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(image, &count) else {
                continue
            }
            defer { free(UnsafeMutableRawPointer(names)) }
            for name in UnsafeBufferPointer(start: names, count: Int(count)) {
                if let linked = objc_lookUpClass(name) {
                    classes.append(linked)
                }
            }
        }
        return classes
    }()

    /// Whether `path` is an OS or toolchain image: macOS's own, a simulator runtime's, or Xcode's
    /// test frameworks.
    ///
    /// - Parameter path: A loaded image's path, as dyld reports it.
    /// - Returns: `true` when no Haruspec stamp can live in the image.
    static func isSystemImage(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/")
            || path.contains("/RuntimeRoot/")
            || path.contains("/Developer/Library/") || path.contains("/Developer/usr/lib/")
    }
}

/// Every stamped double linked into the process. Doubles are `NSObject`-rooted
/// (they back Obj-C injection points), so the Obj-C class list is a complete census; the sweep runs
/// once and only when a derivation actually resolves.
enum SeamDoubleRegistry {
    static let all: [any SeamDouble.Type] = LinkedClasses.all.compactMap { $0 as? any SeamDouble.Type }
}

/// Every stamped forwarder linked into the process, found by the same census as
/// `SeamDoubleRegistry` — forwarders are `NSObject`-rooted.
///
/// The fallback for a spec built without a derived catalog: a catalog names its forwarder, so a
/// derived spec never pays for this census.
enum StampedForwarderRegistry {
    static let all: [any StampedForwarder.Type] = LinkedClasses.all.compactMap { $0 as? any StampedForwarder.Type }

    /// The wrap for a spec over `S`: its stamped forwarder when `S` is a stamped protocol's
    /// existential, identity otherwise.
    ///
    /// - Parameter _: The spec's system type, `(any Cart).self`.
    /// - Returns: A function that wraps a build in the forwarder, or hands it back unchanged.
    static func wrap<S>(_: S.Type) -> (S) -> S {
        guard let forwarder = forwarder(for: S.self) else {
            return { $0 }
        }
        return wrap(S.self, through: forwarder)
    }

    /// The stamped forwarder for `S`, which also names the stamp's derived catalog.
    ///
    /// - Parameter for: The spec's system type, `(any Cart).self`.
    /// - Returns: The generated `Traced<Protocol>`, or `nil` when `S` is not a stamped protocol's
    ///   existential.
    static func forwarder<S>(for _: S.Type) -> (any StampedForwarder.Type)? {
        all.first { ObjectIdentifier($0.forwardedBoundary) == ObjectIdentifier(S.self) }
    }

    /// The wrap for a spec over `S` through a forwarder already in hand.
    ///
    /// - Parameters:
    ///   - _: The spec's system type, `(any Cart).self`.
    ///   - forwarder: The stamped forwarder for `S`, a generated `Traced<Protocol>`.
    /// - Returns: A function that wraps a build in `forwarder`.
    static func wrap<S>(_: S.Type, through forwarder: any StampedForwarder.Type) -> (S) -> S {
        { system in
            guard let wrapped = forwarder.wrap(system) as? S else {
                preconditionFailure("\(forwarder) could not wrap \(type(of: system)) as \(S.self) — file a bug")
            }
            return wrapped
        }
    }
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
    static let all: [any SeamResource.Type] = LinkedClasses.all.compactMap { $0 as? any SeamResource.Type }
}

public extension SeamContext {
    /// The synthesized double serving `boundary`, constructed and registered as an injected
    /// collaborator — exactly `context.double(TracedX.self)` with the X looked up by conformance.
    ///
    /// Derived system factories call this per collaborator parameter. Resolution order: a declared
    /// `.provides` resource, the capture's center for `NotificationCenter`, then the one conforming
    /// double, then a packaged `SeamResource` default. Zero or several candidates trap naming the
    /// fix, because a guessed collaborator would be a silent wiring change.
    func resolve<P>(_ boundary: P.Type) -> P {
        let key = ObjectIdentifier(boundary)
        if let provided = provided(boundary) {
            return provided
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

    /// Returns what the capture itself provides for `boundary`, before any double is considered.
    ///
    /// - Parameter boundary: A parameter type of a build being resolved.
    /// - Returns: A declared resource, the wrapped resolution of an optional, or the capture's
    ///   center; `nil` when none of those serves `boundary`.
    private func provided<P>(_ boundary: P.Type) -> P? {
        // A declared capture resource wins: it is spec-authored, per-capture, and observed through
        // the subject's own surface rather than recorded at a boundary.
        if let make = resourceMakers[ObjectIdentifier(boundary)] {
            guard let resource = make(self) as? P else {
                preconditionFailure(".provides(\(boundary).self) returned a value that is not a \(boundary)")
            }
            return resource
        }
        // An unannotated Obj-C initializer imports as `init!`, so its resource is provided optional.
        if let make = resourceMakers[ObjectIdentifier(P?.self)], let resource = make(self) as? P {
            return resource
        }
        // An unannotated Obj-C parameter imports optional; it takes what its wrapped type resolves to.
        if let optional = boundary as? any ResolvableOptional.Type {
            return optional.resolved(in: self) as? P
        }
        // The capture's own center, the built-in resource every derived init already receives.
        return boundary == NotificationCenter.self ? notifications as? P : nil
    }

    private static func unresolvable(_ boundary: (some Any).Type, candidates: [any SeamDouble.Type]) -> String {
        guard candidates.isEmpty else {
            return "\(candidates.count) doubles serve \(boundary): "
                + candidates.map { "\($0)" }.sorted().joined(separator: ", ")
                + " — resolution must be unambiguous. Author the build: "
                + ".baselined { context in … context.double(\(candidates.map { "\($0)" }.sorted()[0]).self) … }"
        }
        return "nothing serves \(boundary) — declare it: paste its protocol under "
            + "@Haruspec(\"<label>\") refining \(boundary) (a recorded collaborator), provide it "
            + "as a capture resource: .provides(\(boundary).self) { context in … } (isolated "
            + "infrastructure, observed through the subject's reads), or author the wiring: "
            + ".baselined { context in … }"
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

/// An optional parameter type, resolved as its wrapped type.
protocol ResolvableOptional {
    /// Returns the wrapped type resolved in `context`, wrapped back up.
    ///
    /// - Parameter context: The capture resolving the parameter.
    /// - Returns: A non-`nil` optional holding the resolved value.
    static func resolved(in context: SeamContext) -> Any
}

extension Optional: ResolvableOptional {
    static func resolved(in context: SeamContext) -> Any {
        Wrapped?.some(context.resolve(Wrapped.self)) as Any
    }
}
