import Foundation

// The verdict-side twin of `SpecPlan`'s serialization. `verify(replaying:)` runs inside the changed
// build (a test process); the written `result.json` is how the verdict crosses back out to tooling —
// `haruspec report` renders it and exits with its verdict code, so CI gates on the artifact, not on
// scraping test output. Same canonical-encoder discipline as the plan: identical verdicts serialize to
// identical bytes, which is what makes "the reviewer reproduces the exact verdict" checkable.

/// Just the version field, so a result artifact can be gated before its shape is assumed —
/// `SpecPlan`'s stamp discipline, verdict side.
private struct VerdictSchemaStamp: Decodable {
    let schemaVersion: Int
}

/// Thrown when a result artifact can't be rendered by this engine. The verdict is transient CI
/// output, so the remedy is always the same: re-run the verify that wrote it.
public enum SpecVerdictError: Error, Equatable, CustomStringConvertible {
    /// `found` is `nil` for an artifact with no stamp at all — one written before verdicts were
    /// versioned, which this engine refuses rather than part-decodes.
    case unsupportedSchemaVersion(found: Int?, supported: Int)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, supported):
            let stamp = found.map { "schemaVersion \($0)" } ?? "no schemaVersion stamp"
            return "result artifact has \(stamp) (this engine renders \(supported)) — "
                + "re-run the verify to regenerate it"
        }
    }
}

public extension SpecVerdict {
    /// The one verdict schema this engine writes and renders. Version 1 introduced the stamp itself
    /// together with the qualification block (and `Exploration`'s boundary-edge fields) — an
    /// unstamped artifact predates all three. Version 2 added the qualification's `origins`: where the
    /// covered labels are declared, which a version-1 artifact cannot supply and must not pretend to.
    static let supportedSchemaVersion = 2

    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    func jsonData() throws -> Data {
        try Self.canonicalEncoder().encode(self)
    }

    func write(to url: URL) throws {
        try jsonData().write(to: url)
    }

    init(jsonData: Data) throws {
        // Version first, on its own: a pre-stamp artifact has no `schemaVersion` key, and "re-run
        // the verify" is the answer a caller needs — not a keyNotFound. Only the missing key maps
        // to that message; malformed JSON stays its own error.
        let stamp: VerdictSchemaStamp
        do {
            stamp = try JSONDecoder().decode(VerdictSchemaStamp.self, from: jsonData)
        } catch DecodingError.keyNotFound {
            throw SpecVerdictError.unsupportedSchemaVersion(
                found: nil,
                supported: Self.supportedSchemaVersion
            )
        }
        guard stamp.schemaVersion == Self.supportedSchemaVersion else {
            throw SpecVerdictError.unsupportedSchemaVersion(
                found: stamp.schemaVersion,
                supported: Self.supportedSchemaVersion
            )
        }
        self = try JSONDecoder().decode(SpecVerdict.self, from: jsonData)
    }

    init(contentsOf url: URL) throws {
        try self.init(jsonData: Data(contentsOf: url))
    }
}
