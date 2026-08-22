import Foundation

/// Bridges any `Encodable` value into a `CanonicalValue`.
///
/// This is what lets instrumentation capture argument/return *values* without hand-written payload
/// code: most Swift model/DTO types already conform to `Codable`, so a generated `recorder.call(...)`
/// can encode its arguments automatically. Types that aren't `Encodable` degrade gracefully at the
/// call site (record a type name or omit), rather than forcing conformance everywhere.
public extension CanonicalValue {
    /// Encodes through JSON and re-read as a `CanonicalValue`.
    ///
    /// The value is wrapped in a single-element array before encoding so top-level scalars (e.g. a
    /// bare `Int`) are always valid JSON, then unwrapped — `CanonicalValue`'s own `Decodable` does
    /// the structural conversion.
    init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode([value])
        let elements = try JSONDecoder().decode([CanonicalValue].self, from: data)
        self = elements.first ?? .null
    }

    /// Non-throwing convenience: returns `nil` if the value can't be encoded, so call sites can fall
    /// back without a `do/catch`.
    static func encoding(_ value: (some Encodable)?) -> CanonicalValue? {
        guard let value else { return nil }
        return try? CanonicalValue(encoding: value)
    }
}
