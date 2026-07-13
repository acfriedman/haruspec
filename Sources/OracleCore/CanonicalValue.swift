import Foundation

/// A JSON-shaped value used for every payload in a trace.
///
/// Two properties make it the right currency for a *diffable* trace:
///  - **Deterministic ordering.** Object keys are always rendered sorted (`canonicalString`),
///    so two structurally-equal payloads produce identical text regardless of insertion order.
///  - **Structural comparison.** The diff engine walks this tree directly, applying numeric
///    tolerances and volatile-field redaction, rather than comparing opaque strings.
public indirect enum CanonicalValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([CanonicalValue])
    case object([String: CanonicalValue])
}

// MARK: - Rendering

public extension CanonicalValue {
    /// A stable, key-sorted textual form. Used for human-readable diff messages and as an
    /// exact-equality fallback. Not intended to be re-parsed — `Codable` handles serialization.
    var canonicalString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[" + a.map(\.canonicalString).joined(separator: ",") + "]"
        case .object(let o):
            let inner = o.keys.sorted().map { "\"\($0)\":\(o[$0]!.canonicalString)" }
            return "{" + inner.joined(separator: ",") + "}"
        }
    }
}

// MARK: - Codable (round-trips through plain JSON)

extension CanonicalValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([CanonicalValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: CanonicalValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Ergonomic literals (so instrumentation reads naturally)

extension CanonicalValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension CanonicalValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension CanonicalValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}
extension CanonicalValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension CanonicalValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension CanonicalValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: CanonicalValue...) { self = .array(elements) }
}
extension CanonicalValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, CanonicalValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
