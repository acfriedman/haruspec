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
    /// Version 3 added the diff's `unobservedIntent`: which declared intent matched nothing, which
    /// the continuous gate fails on and an earlier artifact never measured. Version 4 carries a
    /// value mismatch structurally (`field`, `baselineValue`, `candidateValue`), so a precise
    /// declaration compares values instead of parsing them out of `detail`. Version 5 added the
    /// exploration's `combinedVariantsCovered`: how much of the seam budget moved every seam at once.
    /// Version 6 added `failingCases` (every failing case a red walked after its first, the reported
    /// one being the richest) and `intentObservations` (where each declaration was first observed).
    /// Version 7 stamps every divergence with the declared op it was recorded under (`op`), which
    /// an op-scoped declaration matches and a report names.
    static let supportedSchemaVersion = 7

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
