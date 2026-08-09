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

/// One typed op argument: the domain it varies over, and how to read a generated value back as `T`.
public struct ArgumentDomain<T> {
    let domain: SeamDomain
    /// The author's name for this argument, if given. Defaults to the argument's position.
    var name: String?
    private let decode: (SeamContext, String) -> T

    init(domain: SeamDomain, name: String? = nil, decode: @escaping (SeamContext, String) -> T) {
        self.domain = domain
        self.name = name
        self.decode = decode
    }

    /// Name this argument, so its seam key — and any counterexample that prints it — reads `add.sku`
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
        argumentDomains = [(seam: keys[0], domain: first.domain)]
    }

    /// Two arguments, delivered together.
    ///
    /// They are sampled *independently* — a domain is still a scalar or a named set, so this cannot by
    /// itself express "a SKU and its real price". What it does fix is where the correlation is drawn:
    /// the op body receives the sku and derives the rest (`Product(sku)`), so a fabricated pair the real
    /// dependency could never return is unrepresentable — the generator only ever picks the sku. A
    /// domain over structured values is the other half, and is deferred to the property-based card.
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
        argumentDomains = [
            (seam: keys[0], domain: first.domain),
            (seam: keys[1], domain: second.domain)
        ]
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
        argumentDomains = [
            (seam: keys[0], domain: first.domain),
            (seam: keys[1], domain: second.domain),
            (seam: keys[2], domain: third.domain)
        ]
    }

    /// Two arguments of one op cannot share a name: they would read the same track, and the second
    /// would consume a cursor the first advanced.
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
