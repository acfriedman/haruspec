import Foundation

// The verdict-side twin of `SpecPlan`'s serialization. `verify(replaying:)` runs inside the changed
// build (a test process); the written `result.json` is how the verdict crosses back out to tooling —
// `haruspec report` renders it and exits with its verdict code, so CI gates on the artifact, not on
// scraping test output. Same canonical-encoder discipline as the plan: identical verdicts serialize to
// identical bytes, which is what makes "the reviewer reproduces the exact verdict" checkable.

public extension SpecVerdict {
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
        self = try JSONDecoder().decode(SpecVerdict.self, from: jsonData)
    }

    init(contentsOf url: URL) throws {
        try self.init(jsonData: Data(contentsOf: url))
    }
}
