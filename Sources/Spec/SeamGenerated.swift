import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

// The reusable custom-type generator: a model declares how it mutates, once, next to itself; a spec
// adopts that declaration with one line. The machinery lives here; the adoption points are
// `Spec.generates(_:)` and the synthesized doubles' `SeamContext.value(_:key:)`.

/// How instances of a model *mutate* — the reusable, standalone form of a custom-type generator.
/// Declared once, next to the model; any spec adopts it with one line, `.generates(Membership.self)`:
///
///     extension Membership: SeamGenerated {
///         static func generated(from fields: FieldSeams) -> Membership {
///             let membership = Membership()
///             membership.tier = fields.string("tier", oneOf: "bronze", "silver", "gold", "Gold")
///             membership.points = Int(fields.int("points", in: 0 ... 1000))
///             return membership
///         }
///     }
///
/// Each field read *carries its domain*, the same way a typed op argument does — so adopting the
/// generator declares the model's whole mutation surface: the fields join `seamPositions`, sweep
/// under the variant budget, and replay identically. Keys are type-scoped (`"Membership.tier"`), so
/// every boundary returning the type shares one declared surface; a spec narrows a field with an
/// explicit `Seam("Membership.tier", …)` in `.vary`, which always wins.
///
/// The factory must be **pure over its field reads**: it runs once at declaration time to discover
/// the domains (no capture bound), and per call during captures. A `Date()` or a random inside it
/// breaks replay the same way any unseamed read does.
public protocol SeamGenerated {
    static func generated(from fields: FieldSeams) -> Self
}

/// The reads a `SeamGenerated` factory builds from. One value, two lives: during a capture it reads
/// through the cassette (recorded, varied, replayed); at declaration time it *discovers* — each read
/// registers its domain and answers the domain's canonical default (a range's lower bound, a
/// choice list's first entry, `false`).
public struct FieldSeams {
    enum Mode {
        case live(SeamContext)
        case discovery(DomainCollector)
    }

    let mode: Mode
    /// The type's name — every field key is `"<Type>.<field>"`, shared by all boundaries returning it.
    let prefix: String

    public func int(_ field: String, in range: ClosedRange<Int64>) -> Int64 {
        let key = "\(prefix).\(field)"
        switch mode {
        case let .live(context): return context.int(key, default: range.lowerBound)
        case let .discovery(collector): collector.register(key, .int(range)); return range.lowerBound
        }
    }

    public func double(_ field: String, in range: ClosedRange<Double>) -> Double {
        let key = "\(prefix).\(field)"
        switch mode {
        case let .live(context): return context.double(key, default: range.lowerBound)
        case let .discovery(collector): collector.register(key, .double(range)); return range.lowerBound
        }
    }

    public func string(_ field: String, oneOf choices: String...) -> String {
        precondition(!choices.isEmpty, "\"\(field)\" declares no choices — a domain must contain a value")
        let key = "\(prefix).\(field)"
        switch mode {
        case let .live(context): return context.string(key, default: choices[0])
        case let .discovery(collector): collector.register(key, .oneOf(choices)); return choices[0]
        }
    }

    public func bool(_ field: String) -> Bool {
        let key = "\(prefix).\(field)"
        switch mode {
        case let .live(context): return context.bool(key, default: false)
        case let .discovery(collector):
            collector.register(key, .anyOf([.bool(false), .bool(true)]))
            return false
        }
    }
}

/// Where a declaration-time dry run deposits the domains its field reads declared.
final class DomainCollector {
    private(set) var domains: [String: SeamDomain] = [:]

    func register(_ key: String, _ domain: SeamDomain) {
        domains[key] = domain
    }
}

public extension SeamContext {
    /// A synthesized custom-type return — the declared factory for `type`, applied to this context.
    /// There is no universal zero for a custom type, so an undeclared one **traps, fail-fast**, naming
    /// the declaration to write. The factory reads its fields through seams, which is what makes the
    /// value recorded, domain-sweepable, and identical on replay.
    func value<T>(_ type: T.Type, key: String) -> T {
        guard let made = valueIfDeclared(type, key: key) else {
            preconditionFailure(
                """
                no generator declared for \(T.self) (needed by the synthesized return "\(key)") — \
                conform the model once and adopt it here:

                    extension \(T.self): SeamGenerated {
                        static func generated(from fields: FieldSeams) -> \(T.self) { … }
                    }
                    // spec: .generates(\(T.self).self)

                or declare a one-off factory: .generates(\(T.self).self) { seams, key in … } — \
                read every field through the seams, so the value replays. Or hand-write this double.
                """
            )
        }
        return made
    }

    /// The optional-return path: a declared factory if there is one, else `nil` — which IS the
    /// sensible zero for an optional, so `-> Receipt?` needs no declaration until a spec wants the
    /// non-nil branch explored.
    func valueIfDeclared<T>(_ type: T.Type, key: String) -> T? {
        guard let make = makers[ObjectIdentifier(type)] else { return nil }
        guard let made = make(self, key) as? T else {
            // Unreachable through `generates(_:_:)`, whose signature ties the key to the closure's
            // return type — this guards only a hand-assembled context.
            preconditionFailure("the generator registered for \(T.self) produced a different type")
        }
        return made
    }
}
