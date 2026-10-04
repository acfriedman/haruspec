import Foundation
import HaruspecCore
import HaruspecSeams

// The op list derived from the boundary protocol, so the mechanical two-thirds of an `.operations`
// block — method bindings and type-heuristic domains — stop being authored. `@Haruspec` on the
// protocol emits a `Derived<Proto>` catalog; `.operations(derivedFrom:)` adopts it, and the authored
// residue is only what a signature cannot state: semantic values ("SAVE10"), and structure (`.last()`).
//
// The collapse is only safe if it cannot manufacture a silent green, so it refuses where it cannot be
// honest. A `String` argument gets no default — random strings explore only the nothing-matches
// branch — and an unresolved argument traps at spec construction naming the exact declaration to
// write. A domain the engine did supply is marked on the verdict ("derived default"), so a green from
// an all-derived spec says so.

/// A derived op catalog — what `@Haruspec` emits as a peer of the boundary protocol.
public protocol DerivedOperations {
    associatedtype System
    static var derivedOps: [DerivedOp<System>] { get }
    /// The derived construction — emitted when the protocol carries a pasted `init` requirement
    /// (the sibling forwarder's `init(resolving:_:)` holds the wiring):
    /// builds the given conformer through the requirement and wraps it. `nil` when construction
    /// has to be authored.
    ///
    /// The conformer is a bare `Any.Type` because a spec generic over `any Proto` has no spelling
    /// for `any Proto.Type`; a type that does not conform traps naming the extension to write.
    static var derivedSystem: ((SeamContext, Any.Type) -> System)? { get }
    /// The boundary's observed properties, one per `var` requirement — the derivation's half of
    /// `.observes(_:)`. Empty when the protocol declares none.
    static var derivedProperties: [DerivedProperty<System>] { get }
    /// The stamped forwarder every build records through, the generated `Traced<Protocol>` — named by the catalog
    /// so a spec need not census the process for it. `nil` sends the spec to that census.
    static var derivedForwarder: (any StampedForwarder.Type)? { get }
}

public extension DerivedOperations {
    static var derivedSystem: ((SeamContext, Any.Type) -> System)? {
        nil
    }

    static var derivedProperties: [DerivedProperty<System>] {
        []
    }

    static var derivedForwarder: (any StampedForwarder.Type)? {
        nil
    }
}

/// One property derived from a protocol `var` requirement: its name, the fully qualified label its
/// writes carry (the stamp's label, as the forwarder records it), and the mechanical read-back the
/// end-state snapshot uses.
public struct DerivedProperty<S> {
    public let name: String
    public let label: String
    /// Async for the same reason `Observed.read` is: an actor port witnesses `{ get async }`.
    public let read: (S) async -> Any

    public init(_ name: String, label: String, read: @escaping (S) async -> Any) {
        self.name = name
        self.label = label
        self.read = read
    }
}

/// Carries a derived op's system across a global-actor hop (`@MainActor func display` driven from
/// a nonisolated op). Emitted by the catalog only for such requirements; the system is the conformer
/// the spec built for one capture, held by nothing else, so the handover cannot race.
public final class UncheckedHandOver<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}

// MARK: - One derived argument

/// One argument of a derived op: its parameter name (the seam-key half and the amendment-matching
/// name), its source-spelled type, and — where the type admits an honest default — a resolution.
public struct DerivedArgument {
    /// How a resolved argument joins a spec: everything `Op.declare(_:key:)` needs, erased so mixed
    /// argument types travel in one list. Built from a typed `ArgumentDomain` and nothing else, so a
    /// derived argument and a hand-declared one are the same machinery by construction.
    struct Resolution {
        /// What this argument adds to the declared surface, given the op label and position.
        let contributions: (String, Int) -> [(seam: String, domain: SeamDomain)]
        /// The factory a `.generated` argument registers, `nil` for a scalar.
        let maker: (type: ObjectIdentifier, make: (SeamContext, String) -> Any)?
        /// Reads one generated value back, erased. `(seams, opLabel, position) -> value`.
        let read: (SeamContext, String, Int) -> Any
        /// Whether contributions are a generated model's type-scoped fields (merged fill-if-vacant)
        /// rather than an op-scoped scalar key (merged trap-on-collision).
        let isGenerated: Bool
    }

    let name: String
    let typeName: String
    var resolution: Resolution?
    /// Whether the resolution is an engine default rather than authored — the qualification marker.
    /// A `.generated` model is authored (its `SeamGenerated` conformance is the declaration).
    var isDerivedDefault: Bool

    /// A wide integer parameter (`Int`, `Int64`, `Int32`, `Int16`, `NSInteger`), defaulted to the
    /// magnitude ladder over `SpecDefaults.derivedIntSpan`.
    public static func int(_ name: String) -> DerivedArgument {
        magnitudeInt(name, over: SpecDefaults.derivedIntSpan)
    }

    /// An `Int8` parameter — the same ladder, clipped to what the width can represent (the emitted
    /// `Int8(_:)` conversion traps on overflow, so the domain must not claim more).
    public static func int8(_ name: String) -> DerivedArgument {
        magnitudeInt(name, over: SpecDefaults.derivedTinyIntSpan)
    }

    /// An unsigned parameter (`UInt`, `UInt64`, `UInt32`, `UInt16`) — no negative side to ladder.
    public static func uint(_ name: String) -> DerivedArgument {
        magnitudeInt(name, over: SpecDefaults.derivedUnsignedSpan)
    }

    /// A `UInt8` parameter — unsigned and width-clipped.
    public static func uint8(_ name: String) -> DerivedArgument {
        magnitudeInt(name, over: SpecDefaults.derivedUnsignedTinySpan)
    }

    /// A `Double`-family parameter, defaulted to the fractional-through-thousands ladder.
    public static func double(_ name: String) -> DerivedArgument {
        // Canonical golden value 0, not a span bound: the recorded path should read naturally.
        let domain = ArgumentDomain<Double>(
            domain: .doubleMagnitudes(SpecDefaults.derivedDoubleSpan),
            name: name
        ) { seams, seam in
            seams.double(seam, default: 0)
        }
        return DerivedArgument(name: name, typeName: "Double", resolution: domain.erased(), isDerivedDefault: true)
    }

    private static func magnitudeInt(_ name: String, over span: ClosedRange<Int64>) -> DerivedArgument {
        // All widths read back as `Int` (the emitted conversion narrows), so one typeName — an
        // amendment's `.int(…)`/`.oneOf(Int)` domain replaces any width's default.
        let domain = ArgumentDomain<Int>(domain: .intMagnitudes(span), name: name) { seams, seam in
            Int(seams.int(seam, default: 0))
        }
        return DerivedArgument(name: name, typeName: "Int", resolution: domain.erased(), isDerivedDefault: true)
    }

    /// A `Bool` parameter. Both values are boundary values, so the default is the whole domain.
    public static func bool(_ name: String) -> DerivedArgument {
        DerivedArgument(
            name: name,
            typeName: "Bool",
            resolution: ArgumentDomain<Bool>.bool().named(name).erased(),
            isDerivedDefault: true
        )
    }

    /// A `String` parameter — deliberately pending. A string argument is where magic values live
    /// (a promo code, a status), and a random default would sweep only the nothing-matches branch:
    /// EQUIVALENT over a surface that never reached the interesting one. Unresolved, it traps at
    /// spec construction naming the declaration to write.
    public static func string(_ name: String) -> DerivedArgument {
        DerivedArgument(name: name, typeName: "String", resolution: nil, isDerivedDefault: false)
    }

    /// A parameter no heuristic covers (a collection, a closure) — pending, resolvable only by
    /// overriding the whole op.
    public static func pending(_ name: String, type: String) -> DerivedArgument {
        DerivedArgument(name: name, typeName: type, resolution: nil, isDerivedDefault: false)
    }

    /// A model parameter, built by its own `SeamGenerated` factory — the factory is the authored
    /// declaration, so this is not a derived default.
    public static func generated<T: SeamGenerated>(
        _ name: String,
        _ type: T.Type
    ) -> DerivedArgument where T.Generated == T {
        DerivedArgument(
            name: name,
            typeName: "\(T.self)",
            resolution: ArgumentDomain<T>.generated(type).named(name).erased(),
            isDerivedDefault: false
        )
    }

    /// A model parameter whose type has no `SeamGenerated` factory, left pending so a catalog no spec
    /// drives still compiles. A spec that drives this op traps at construction naming the argument.
    ///
    /// - Parameters:
    ///   - name: The parameter's name, the seam-key half and the amendment-matching name.
    ///   - _: The parameter's type, named in the pending argument.
    /// - Returns: A pending argument, with no domain until an amendment declares one.
    ///
    /// Overload resolution prefers the `SeamGenerated` form whenever the conformance exists.
    public static func generated<T>(_ name: String, _: T.Type) -> DerivedArgument {
        pending(name, type: "\(T.self)")
    }
}

extension ArgumentDomain {
    var typeName: String {
        "\(T.self)"
    }

    /// Erases for the derived-op pipeline. The domain must already carry the argument's final name —
    /// the synthesized key reads it.
    func erased() -> DerivedArgument.Resolution {
        DerivedArgument.Resolution(
            contributions: { label, position in self.contributions(for: label, at: position) },
            maker: maker,
            read: { seams, label, position in self.read(seams, seam: self.key(for: label, at: position)) },
            isGenerated: maker != nil
        )
    }
}

extension ArgumentDomain where T == Bool {
    /// The two-value domain a `Bool` argument defaults to. Categorical, so both values are edges.
    static func bool() -> ArgumentDomain<Bool> {
        ArgumentDomain(domain: .anyOf([.bool(false), .bool(true)])) { seams, seam in
            seams.bool(seam, default: false)
        }
    }
}

// MARK: - One derived op

/// Ordering/repetition state shared by derived ops and `Amend` amendments — mirrors the `Op`
/// modifiers it is later applied through.
struct OpStructure {
    var mustBeLast = false
    var multiplicity: ClosedRange<Int>?
    var afters: [String] = []
    var gates: [String] = []
}

/// One op derived from a protocol requirement: the mechanical binding (label, arguments, call), with
/// its structure and any pending domains still open to amendment.
public struct DerivedOp<S> {
    public let label: String
    var arguments: [DerivedArgument]
    let action: (S, [Any]) async -> Void
    var structure = OpStructure()

    public init(_ label: String, arguments: [DerivedArgument] = [], action: @escaping (S, [Any]) async -> Void) {
        precondition(
            Set(arguments.map(\.name)).count == arguments.count,
            "\(label) declares two arguments with the same name — they would share one seam track"
        )
        self.label = label
        self.arguments = arguments
        self.action = action
    }

    /// The op-scoped keys whose domains the engine supplied — the qualification's "derived default"
    /// marker. Generated models and amended domains are authored, so they never appear here.
    var derivedDefaultKeys: [String] {
        arguments.filter(\.isDerivedDefault).map { "\(label).\($0.name)" }
    }

    /// The runnable `Op`, or a trap naming the declaration a pending argument still needs.
    func resolved() -> Op<S> {
        for argument in arguments where argument.resolution == nil {
            preconditionFailure(
                "derived op '\(label)' has no domain for '\(argument.name): \(argument.typeName)' — "
                    + "a \(argument.typeName) has no honest default. Declare its values: "
                    + "Amend(\"\(label)\").varying(\"\(argument.name)\", over: .oneOf(…)) — "
                    + "or replace the op: Op(\"\(label)\", varying: …) { … }"
            )
        }
        let label = label
        let arguments = arguments
        let action = action
        var op = Op<S>(label) { system, seams in
            var values: [Any] = []
            for (position, argument) in arguments.enumerated() {
                values.append(argument.resolution!.read(seams, label, position))
            }
            await action(system, values)
        }
        for (position, argument) in arguments.enumerated() {
            let resolution = argument.resolution!
            if resolution.isGenerated {
                op.generatedArgumentFields += resolution.contributions(label, position)
                if let maker = resolution.maker {
                    op.argumentMakers.append(maker)
                }
            } else {
                op.argumentDomains += resolution.contributions(label, position)
            }
        }
        if let multiplicity = structure.multiplicity {
            op = op.repeating(multiplicity)
        } else if !structure.mustBeLast {
            // The derived default: a modest *range*, because absence is what reaches the states a
            // fixed count never does (a checkout on an empty cart). `.last()` implies once.
            op = op.repeating(SpecDefaults.derivedRepetition)
        }
        for after in structure.afters {
            op = op.after(after)
        }
        for gate in structure.gates {
            op = op.requires(gate)
        }
        if structure.mustBeLast {
            op = op.last()
        }
        return op
    }
}

// MARK: - Amendments (the authored residue)

/// A domain supplied by a `Amend.varying(_:over:)`, held until the match — the seam key uses the
/// *argument's* name, so erasure waits for it.
struct SuppliedDomain {
    /// The parameter this domain fills, as named in the protocol signature.
    let name: String
    let typeName: String
    let resolve: (String) -> DerivedArgument.Resolution
}

/// An amendment to one derived op: fill a pending domain, tighten a default, or add structure —
/// without re-authoring the binding the derivation already wrote. One modifier grammar throughout:
///
///     Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
///     Amend("checkout").last()
public struct Amend {
    let label: String
    var supplied: [SuppliedDomain] = []
    var structure = OpStructure()

    public init(_ label: String) {
        self.label = label
    }

    /// Varies `parameter` over `domain` — the parameter-first form of a domain declaration: the name
    /// is the join to the signature, so it anchors the call rather than trailing the domain.
    public func varying(_ parameter: String, over domain: ArgumentDomain<some Any>) -> Amend {
        precondition(
            domain.name == nil || domain.name == parameter,
            "the domain is .named(\"\(domain.name ?? "")\") but applied to '\(parameter)' — "
                + "drop the .named; the parameter argument is the name"
        )
        var copy = self
        copy.supplied.append(
            SuppliedDomain(name: parameter, typeName: domain.typeName) { argumentName in
                domain.named(argumentName).erased()
            }
        )
        return copy
    }

    /// Requires this op to run last. Implies once — mirrors `Op.last()`.
    public func last() -> Amend {
        var copy = self; copy.structure.mustBeLast = true; return copy
    }

    /// Exempts this op from ordering repetition, so it runs exactly once per sequence — mirrors `Op.once()`.
    public func once() -> Amend {
        repeating(1)
    }

    /// Applies exactly `count` times — mirrors `Op.repeating(_:)`.
    public func repeating(_ count: Int) -> Amend {
        repeating(count ... count)
    }

    /// Applies between `range` times, varying per sequence — mirrors `Op.repeating(_:)`.
    public func repeating(_ range: ClosedRange<Int>) -> Amend {
        var copy = self; copy.structure.multiplicity = range; return copy
    }

    /// Soft precondition — mirrors `Op.after(_:)`.
    public func after(_ label: String) -> Amend {
        var copy = self; copy.structure.afters.append(label); return copy
    }

    /// Hard ordering gate — mirrors `Op.requires(_:)`.
    public func requires(_ label: String) -> Amend {
        var copy = self; copy.structure.gates.append(label); return copy
    }
}

extension DerivedOp {
    /// Applies one amendment: matches each supplied domain to its argument by name, checks the types
    /// agree, and folds the structure in.
    func amended(by amendment: Amend) -> DerivedOp<S> {
        var copy = self
        for supplied in amendment.supplied {
            guard let index = copy.arguments.firstIndex(where: { $0.name == supplied.name }) else {
                preconditionFailure(
                    "'\(label)' has no argument named '\(supplied.name)' — it declares "
                        + copy.arguments.map { "'\($0.name): \($0.typeName)'" }.joined(separator: ", ")
                )
            }
            precondition(
                copy.arguments[index].typeName == supplied.typeName,
                "'\(label).\(copy.arguments[index].name)' is \(copy.arguments[index].typeName); "
                    + "the declared domain generates \(supplied.typeName)"
            )
            copy.arguments[index].resolution = supplied.resolve(copy.arguments[index].name)
            copy.arguments[index].isDerivedDefault = false
        }
        if amendment.structure.mustBeLast {
            copy.structure.mustBeLast = true
        }
        if let multiplicity = amendment.structure.multiplicity {
            copy.structure.multiplicity = multiplicity
        }
        copy.structure.afters += amendment.structure.afters
        copy.structure.gates += amendment.structure.gates
        return copy
    }
}

// MARK: - The override block

/// One entry in an `.operations(derivedFrom:)` block: amend a derived op, or replace it wholesale
/// with an authored `Op` (the escape hatch for a binding the derivation cannot write).
public enum OperationOverride<S> {
    case amend(Amend)
    case replace(Op<S>)
}

@resultBuilder public enum OperationOverridesBuilder<S> {
    public static func buildExpression(_ amendment: Amend) -> OperationOverride<S> {
        .amend(amendment)
    }

    public static func buildExpression(_ operation: Op<S>) -> OperationOverride<S> {
        .replace(operation)
    }

    public static func buildBlock(_ overrides: OperationOverride<S>...) -> [OperationOverride<S>] {
        overrides
    }
}

// MARK: - Adoption

public extension Spec {
    /// Adopts a protocol's derived op catalog, with the authored residue as overrides.
    ///
    /// Everything mechanical comes from the derivation: one op per requirement, bindings, and
    /// type-heuristic domains (marked "derived default" on the verdict). The block holds only what a
    /// signature cannot state — `Amend("applyPromo").varying("code", over: .oneOf(…))` fills a
    /// pending domain or tightens a default, `Amend("checkout").last()` adds structure, and a full
    /// `Op` replaces its derived twin when the binding itself must differ. Ops keep protocol
    /// declaration order; an override naming no derived op traps, so a typo cannot silently add a
    /// second op.
    func operations<D: DerivedOperations>(
        derivedFrom _: D.Type,
        @OperationOverridesBuilder<S> overriding build: () -> [OperationOverride<S>] = { [] }
    ) -> Spec<S> where D.System == S {
        var slots = D.derivedOps.map { Slot.derived($0) }
        let labels = D.derivedOps.map(\.label)
        for override in build() {
            switch override {
            case let .amend(amendment):
                guard let index = labels.firstIndex(of: amendment.label) else {
                    preconditionFailure(unknownLabel(amendment.label, in: labels))
                }
                guard case let .derived(current) = slots[index] else {
                    preconditionFailure("'\(amendment.label)' was already replaced — amend or replace, not both")
                }
                slots[index] = .derived(current.amended(by: amendment))
            case let .replace(operation):
                guard let index = labels.firstIndex(of: operation.label) else {
                    preconditionFailure(unknownLabel(operation.label, in: labels))
                }
                slots[index] = .replaced(operation)
            }
        }
        var derivedDefaults: Set<String> = []
        let ops = slots.map { slot -> Op<S> in
            switch slot {
            case let .replaced(operation):
                return operation
            case let .derived(derived):
                derivedDefaults.formUnion(derived.derivedDefaultKeys)
                return derived.resolved()
            }
        }
        var copy = adopting(ops)
        copy.derivedDefaultSeams = derivedDefaults
        if let forwarder = D.derivedForwarder {
            copy.wrapCandidate = StampedForwarderRegistry.wrap(S.self, through: forwarder)
        }
        // The protocol's `var` requirements become observed properties, snapshot at every capture
        // boundary.
        copy.observedProperties += D.derivedProperties.map { property in
            Observed(property.label, property.read)
        }
        // Derived specs explore by default: ordering variation and a bounded budget are part of what
        // "derive it" means, so `.vary` becomes the override site rather than the on-switch. An
        // explicit `.vary` — before or after — wins.
        if !copy.exploreOrdering {
            copy.exploreOrdering = true
            copy.maxOrderings = SpecDefaults.derivedOrderingMax
        }
        if copy.explorationBudget == nil {
            copy.explorationBudget = SpecDefaults.derivedBudget
        }
        return copy
    }
}

public extension Spec {
    /// The collapsed spec: name, derived catalog, and authored residue in one entry point. Names no
    /// implementation — a test binds the baseline with ``baselined(on:)``, built and wrapped along the
    /// same path its ports are checked through.
    ///
    /// - Parameters:
    ///   - name: The spec's name, unique within the catalog.
    ///   - source: The derived catalog, as `@Haruspec` generated it from the boundary protocol.
    ///   - build: Amendments to the derived ops; empty leaves the catalog as derived.
    ///
    /// Exploration runs at the derived defaults, and `.vary` overrides them. The whole spec for a
    /// derived catalog reads:
    ///
    ///     Spec<Cart>("cart", derivedFrom: DerivedCart.self) {
    ///         Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
    ///         Amend("checkout").last()
    ///     }
    init<D: DerivedOperations>(
        _ name: String,
        derivedFrom source: D.Type,
        @OperationOverridesBuilder<S> overriding build: () -> [OperationOverride<S>] = { [] }
    ) where D.System == S {
        self.init(name)
        makeConformer = D.derivedSystem
        self = operations(derivedFrom: source, overriding: build)
    }
}

private enum Slot<S> {
    case derived(DerivedOp<S>)
    case replaced(Op<S>)
}

private func unknownLabel(_ label: String, in labels: [String]) -> String {
    "'\(label)' matches no derived op — the derivation declares \(labels.joined(separator: ", ")). "
        + "An op the protocol doesn't declare belongs in a plain .operations block"
}
