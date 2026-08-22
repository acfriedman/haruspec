import Foundation
import HaruspecCore
import HaruspecSeams

// Declaring an argument's domain *where the argument is used*, so `.operations` and `.vary` stop being
// joined by an unchecked string.
//
// The string form has two silent failure directions. A domain declared for a key no op reads is dropped
// at the `seamDomains.keys ∩ declared` intersection — no gap, no warning. And a mistyped *read* falls
// back to its `default:`, records that one constant into the golden, and sweeps it: the run reports
// EQUIVALENT over a surface it never varied, which is a false negative wearing a green banner. Neither
// is expressible here. There is one declaration, at the use site, and the key that joins it to the
// cassette is synthesized rather than typed.
//
// `SeamDomain` is erased — `.anyOf` holds strings or ints alike — so it cannot hand the op body a typed
// value on its own. `ArgumentDomain<T>` carries the erased domain *plus* how to read one back as `T`,
// which is what lets the body take `quantity: Int` instead of unwrapping a `CanonicalValue`.

/// One typed op argument: what it varies over, and how to read a generated value back as `T`.
///
/// Two shapes. A *scalar* argument owns one domain under a synthesized op-scoped key (`add.sku`). A
/// *generated* argument (`.generated(Product.self)`) is a whole model built by its `SeamGenerated`
/// factory: it contributes the type-scoped field domains the factory declared (`Product.sku`), and
/// registers the factory so the read can build the value.
public struct ArgumentDomain<T> {
    enum Kind {
        /// One erased domain, keyed `<op>.<name-or-position>`.
        case scalar(SeamDomain)
        /// A `SeamGenerated` model: its discovered field domains (type-scoped keys) and its factory.
        case generated(fields: [String: SeamDomain], maker: (SeamContext, String) -> Any)
    }

    let kind: Kind
    /// The author's name for this argument, if given. Defaults to the argument's position.
    var name: String?
    private let decode: (SeamContext, String) -> T

    init(domain: SeamDomain, name: String? = nil, decode: @escaping (SeamContext, String) -> T) {
        kind = .scalar(domain)
        self.name = name
        self.decode = decode
    }

    init(kind: Kind, decode: @escaping (SeamContext, String) -> T) {
        self.kind = kind
        self.decode = decode
    }

    /// Names this argument, so its seam key — and any counterexample that prints it — reads `add.sku`
    /// rather than `add.0`. This is identity declared once at the use site, not the key the typed form
    /// exists to stop you typing twice; nothing has to agree with it elsewhere.
    ///
    /// It *is* part of the replay contract, like an op label: renaming an argument orphans the input
    /// recorded against the old key, which surfaces as a coverage gap rather than a silent pass.
    public func named(_ name: String) -> ArgumentDomain<T> {
        var copy = self
        copy.name = name
        return copy
    }

    /// `<op>.<name-or-position>` — synthesized, so there is no second place to keep it in sync.
    func key(for label: String, at position: Int) -> String {
        "\(label).\(name ?? String(position))"
    }

    func read(_ seams: SeamContext, seam: String) -> T {
        decode(seams, seam)
    }

    /// What this argument adds to the declared surface: the synthesized-key scalar domain, or the
    /// model's type-scoped field domains.
    func contributions(for label: String, at position: Int) -> [(seam: String, domain: SeamDomain)] {
        switch kind {
        case let .scalar(domain):
            [(seam: key(for: label, at: position), domain: domain)]
        case let .generated(fields, _):
            fields.map { (seam: $0.key, domain: $0.value) }.sorted { $0.seam < $1.seam }
        }
    }

    /// The factory to register for a generated argument, `nil` for a scalar.
    var maker: (type: ObjectIdentifier, make: (SeamContext, String) -> Any)? {
        guard case let .generated(_, make) = kind else { return nil }
        return (ObjectIdentifier(T.self), make)
    }
}

public extension ArgumentDomain where T: SeamGenerated, T.Generated == T {
    /// A whole generated model as an op input — the structured half the scalar domains cannot express.
    ///
    /// The model's `SeamGenerated` factory is the single place its invariants live: a `Product`
    /// generator picks the SKU from a domain and *derives* the price from the catalogue, so a pair
    /// the real dependency could never produce is unrepresentable. Fields are discovered here, at
    /// declaration time, under the model's type-scoped keys (`Product.sku`) — swept, reported, and
    /// narrowable with an explicit `Seam` exactly like a `.generates` adoption; no separate
    /// `.generates` call is needed for the argument.
    static func generated(_: T.Type) -> ArgumentDomain<T> {
        let discovery = DomainCollector()
        _ = T.generated(from: FieldSeams(mode: .discovery(discovery), prefix: "\(T.self)"))
        return ArgumentDomain(
            kind: .generated(
                fields: discovery.domains,
                maker: { context, _ in T.generated(from: FieldSeams(mode: .live(context), prefix: "\(T.self)")) }
            ),
            decode: { seams, _ in seams.value(T.self, key: "\(T.self)") }
        )
    }
}

// MARK: - The domains an argument can take

public extension ArgumentDomain where T == Int {
    /// A range, delivered as `Int` — the type a call site actually wants, rather than the `Int64` the
    /// cassette stores.
    static func int(_ range: ClosedRange<Int>) -> ArgumentDomain<Int> {
        ArgumentDomain(domain: .int(Int64(range.lowerBound) ... Int64(range.upperBound))) { seams, seam in
            Int(seams.int(seam, default: Int64(range.lowerBound)))
        }
    }

    /// A named set of integers — the categorical axis where the interesting values aren't a range.
    static func oneOf(_ values: [Int]) -> ArgumentDomain<Int> {
        precondition(!values.isEmpty, "oneOf needs at least one value to vary over")
        let fallback = Int64(values[0])
        return ArgumentDomain(domain: .oneOf(values.map(Int64.init))) { seams, seam in
            Int(seams.int(seam, default: fallback))
        }
    }

    static func oneOf(_ values: Int...) -> ArgumentDomain<Int> {
        oneOf(values)
    }
}

public extension ArgumentDomain where T == Double {
    static func double(_ range: ClosedRange<Double>) -> ArgumentDomain<Double> {
        ArgumentDomain(domain: .double(range)) { seams, seam in
            seams.double(seam, default: range.lowerBound)
        }
    }
}

public extension ArgumentDomain where T == String {
    /// A named set of strings — SKUs, promo codes, status values. Every declared value is a boundary
    /// value, so each is reached by construction rather than by sampling luck.
    static func oneOf(_ values: [String]) -> ArgumentDomain<String> {
        precondition(!values.isEmpty, "oneOf needs at least one value to vary over")
        let fallback = values[0]
        return ArgumentDomain(domain: .oneOf(values)) { seams, seam in
            seams.string(seam, default: fallback)
        }
    }

    static func oneOf(_ values: String...) -> ArgumentDomain<String> {
        oneOf(values)
    }
}

// MARK: - Ops that take their arguments

public extension Op {
    /// An op whose argument is property-varied, with the domain declared where the argument is used.
    /// The string form (`Op(_:)` + `seams.int(_:default:)`) still works and is the escape hatch for a
    /// seam whose key isn't known statically.
    init<A>(
        _ label: String,
        varying first: ArgumentDomain<A>,
        _ action: @escaping (S, A) async -> Void
    ) {
        let keys = Self.keys(label, [first.name])
        self.init(label) { system, seams in
            await action(system, first.read(seams, seam: keys[0]))
        }
        declare(first, key: keys[0])
    }

    /// Two arguments, delivered together.
    ///
    /// Scalar domains are sampled *independently* — they cannot by themselves express "a SKU and its
    /// real price"; the op body receives the sku and derives the rest, so a fabricated pair is
    /// unrepresentable. `.generated(_:)` is the structured other half: the model's own factory draws
    /// the fields and encodes the correlation once, next to the model.
    init<A, B>(
        _ label: String,
        varying first: ArgumentDomain<A>,
        _ second: ArgumentDomain<B>,
        _ action: @escaping (S, A, B) async -> Void
    ) {
        let keys = Self.keys(label, [first.name, second.name])
        self.init(label) { system, seams in
            await action(system, first.read(seams, seam: keys[0]), second.read(seams, seam: keys[1]))
        }
        declare(first, key: keys[0])
        declare(second, key: keys[1])
    }

    init<A, B, C>(
        _ label: String,
        varying first: ArgumentDomain<A>,
        _ second: ArgumentDomain<B>,
        _ third: ArgumentDomain<C>,
        _ action: @escaping (S, A, B, C) async -> Void
    ) {
        let keys = Self.keys(label, [first.name, second.name, third.name])
        self.init(label) { system, seams in
            await action(
                system,
                first.read(seams, seam: keys[0]),
                second.read(seams, seam: keys[1]),
                third.read(seams, seam: keys[2])
            )
        }
        declare(first, key: keys[0])
        declare(second, key: keys[1])
        declare(third, key: keys[2])
    }

    /// Folds one argument into the op's declared surface: a scalar owns its synthesized key; a
    /// generated model contributes its type-scoped field domains and the factory that builds it.
    private mutating func declare(_ argument: ArgumentDomain<some Any>, key: String) {
        switch argument.kind {
        case let .scalar(domain):
            argumentDomains.append((seam: key, domain: domain))
        case let .generated(fields, _):
            generatedArgumentFields += fields.map { (seam: $0.key, domain: $0.value) }
                .sorted { $0.seam < $1.seam }
            if let maker = argument.maker {
                argumentMakers.append((type: maker.type, make: maker.make))
            }
        }
    }

    /// Two arguments of one op cannot share a name: they would read the same track, and the second
    /// would consume a cursor the first advanced. (A generated argument reads no op-scoped track;
    /// its position holds a synthesized key nothing consumes.)
    private static func keys(_ label: String, _ names: [String?]) -> [String] {
        let keys = names.enumerated().map { position, name in
            "\(label).\(name ?? String(position))"
        }
        precondition(
            Set(keys).count == keys.count,
            "\(label) declares two arguments with the same name — they would share one seam track"
        )
        return keys
    }
}
