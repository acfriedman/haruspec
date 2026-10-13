import Foundation

/// A JSON-shaped value used for every payload in a trace.
///
/// Two properties make it the right currency for a *diffable* trace:
///  - **Deterministic ordering.** Object keys are always rendered sorted (`canonicalString`),
///    so two structurally-equal payloads produce identical text regardless of insertion order.
///  - **Structural comparison.** The diff engine walks this tree directly, applying numeric
///    comparison and volatile-field redaction, rather than comparing opaque strings.
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
    /// A stable, key-sorted textual form of the value. It exists for human-readable diff messages
    /// and as an exact-equality fallback, never for re-parsing; `Codable` handles serialization.
    ///
    /// A string, and an object key, is a JSON string literal with everything that would not show as
    /// itself escaped: a quote, a backslash, a line break, a tab, a control, an invisible or
    /// look-alike space, an unassigned code point. So a rendering is always one line, and two
    /// different values never render alike.
    var canonicalString: String {
        switch self {
        case .null: return "null"
        case let .bool(bool): return bool ? "true" : "false"
        case let .int(int): return String(int)
        case let .double(double): return String(double)
        case let .string(string): return Self.quoted(string)
        case let .array(array): return "[" + array.map(\.canonicalString).joined(separator: ",") + "]"
        case let .object(object):
            let inner = object.keys.sorted().map { "\(Self.quoted($0)):\(object[$0]!.canonicalString)" }
            return "{" + inner.joined(separator: ",") + "}"
        }
    }
}

// MARK: - String escaping

private extension CanonicalValue {
    /// The tag characters, which spell a subdivision flag inside an emoji.
    static let emojiTags: ClosedRange<Unicode.Scalar> = "\u{E0020}" ... "\u{E007F}"

    /// Returns `text` as a JSON string literal that shows every character in it.
    ///
    /// - Parameter text: Any string.
    /// - Returns: `text` in double quotes; visible characters as themselves, everything else escaped.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for character in text {
            // A joiner or a tag inside an emoji is part of how it draws: escaping it would split
            // one visible glyph into several.
            let isEmoji = character.unicodeScalars.contains(where: \.properties.isEmojiPresentation)
            for (position, scalar) in character.unicodeScalars.enumerated() {
                if isEmoji, scalar == "\u{200D}" || emojiTags.contains(scalar) {
                    result.unicodeScalars.append(scalar)
                } else if position == 0, isMark(scalar) {
                    // A mark with no base in the string would draw onto the quote or escape before it.
                    result += unicodeEscape(scalar)
                } else {
                    result += escaped(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Returns whether `scalar` is a combining mark, which draws onto the character before it.
    ///
    /// - Parameter scalar: Any Unicode scalar.
    /// - Returns: `true` for a nonspacing, spacing, or enclosing mark.
    static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    /// Returns one scalar as it appears inside a quoted string.
    ///
    /// - Parameter scalar: Any Unicode scalar.
    /// - Returns: The scalar itself when it shows as itself; otherwise its JSON escape — the short
    ///   form for a quote, backslash, line feed, carriage return, or tab, and `\uXXXX` (a surrogate
    ///   pair above the Basic Multilingual Plane) for anything else.
    static func escaped(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "\"": return "\\\""
        case "\\": return "\\\\"
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        default: break
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned:
            break
        case .spaceSeparator where scalar != " ":
            break
        default:
            return String(scalar)
        }
        return unicodeEscape(scalar)
    }

    /// Returns `scalar` as JSON's `\uXXXX` escape.
    ///
    /// - Parameter scalar: Any Unicode scalar.
    /// - Returns: One escape for a scalar in the Basic Multilingual Plane, a surrogate pair of two
    ///   above it.
    static func unicodeEscape(_ scalar: Unicode.Scalar) -> String {
        String(scalar).utf16.map { "\\u" + hex($0) }.joined()
    }

    /// Returns `unit` as four uppercase hex digits.
    ///
    /// - Parameter unit: A UTF-16 code unit.
    /// - Returns: The digits, zero-padded.
    static func hex(_ unit: UInt16) -> String {
        let digits = String(unit, radix: 16, uppercase: true)
        return String(repeating: "0", count: 4 - digits.count) + digits
    }
}

public extension CanonicalValue {
    /// The kind of value this is, and for a string its format — what a reader needs to recognize a
    /// value the subject made up itself (a fresh identifier, a clock reading) without seeing it.
    ///
    /// Names the kind for a non-string; a string is an empty string, an upper- or lowercase UUID
    /// (the case a producer emits is part of its format), an ISO 8601 timestamp with or without
    /// fractional seconds, or plain string.
    var shape: String {
        switch self {
        case let .string(text): Self.stringShape(text)
        case .int: "int"
        case .double: "double"
        case .bool: "bool"
        case .null: "null"
        case .array: "array"
        case .object: "object"
        }
    }

    /// Returns the hint a mismatch carries when both values look minted rather than computed: two
    /// identifiers, or two timestamps, of the same format.
    ///
    /// - Parameters:
    ///   - baseline: The recorded value.
    ///   - candidate: The value that differed from it.
    /// - Returns: The hint, naming the source to inject; `nil` when either value is not an identifier
    ///   or timestamp, or the two differ in format, which is a change of its own.
    ///
    /// A replay against a plan recorded earlier sees a coarse clock read differ on every pass alike,
    /// so the mismatch is stable and reads as the candidate's. Only the values' shape can say it is
    /// likely an uncontrolled seam instead; a controlled seam never mismatches, so it never carries one.
    static func mintedHint(_ baseline: CanonicalValue, _ candidate: CanonicalValue) -> String? {
        guard baseline.shape == candidate.shape else {
            return nil
        }
        switch baseline.shape {
        case "UUID", "uuid", "mixed-case uuid":
            return "likely an uncontrolled seam: inject the identifier's source"
        case "ISO 8601 timestamp", "ISO 8601 timestamp, fractional seconds":
            return "likely an uncontrolled seam: inject the clock"
        default:
            return nil
        }
    }

    private static func stringShape(_ text: String) -> String {
        if text.isEmpty {
            return "empty string"
        }
        if UUID(uuidString: text) != nil {
            return text == text.uppercased() ? "UUID" : text == text.lowercased() ? "uuid" : "mixed-case uuid"
        }
        let timestamp = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$"#
        let match = text.range(of: timestamp, options: .regularExpression)
        if match == text.startIndex ..< text.endIndex {
            return text.contains(".") ? "ISO 8601 timestamp, fractional seconds" : "ISO 8601 timestamp"
        }
        return "string"
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
