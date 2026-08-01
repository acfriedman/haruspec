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
        case let .bool(bool): return bool ? "true" : "false"
        case let .int(int): return String(int)
        case let .double(double): return String(double)
        case let .string(string): return "\"\(string)\""
        case let .array(array): return "[" + array.map(\.canonicalString).joined(separator: ",") + "]"
        case let .object(object):
            let inner = object.keys.sorted().map { "\"\($0)\":\(object[$0]!.canonicalString)" }
            return "{" + inner.joined(separator: ",") + "}"
        }
    }
}

// MARK: - Codable (round-trips through plain JSON)

extension CanonicalValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null; return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool); return
        }
        if let int = try? container.decode(Int64.self) {
            self = .int(int); return
        }
        if let double = try? container.decode(Double.self) {
            self = .double(double); return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string); return
        }
        if let array = try? container.decode([CanonicalValue].self) {
            self = .array(array); return
        }
        if let object = try? container.decode([String: CanonicalValue].self) {
            self = .object(object); return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(bool): try container.encode(bool)
        case let .int(int): try container.encode(int)
        case let .double(double): try container.encode(double)
        case let .string(string): try container.encode(string)
        case let .array(array): try container.encode(array)
        case let .object(object): try container.encode(object)
        }
    }
}

// MARK: - Ergonomic literals (so instrumentation reads naturally)

extension CanonicalValue: ExpressibleByNilLiteral {
    public init(nilLiteral _: ()) {
        self = .null
    }
}

extension CanonicalValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension CanonicalValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .int(value)
    }
}

extension CanonicalValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension CanonicalValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension CanonicalValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: CanonicalValue...) {
        self = .array(elements)
    }
}

extension CanonicalValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, CanonicalValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
