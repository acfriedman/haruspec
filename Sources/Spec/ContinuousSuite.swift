import Foundation

// A spec's continuous run lives in an ordinary test suite the adopter writes. The engine cannot see
// which one — so a suite that names itself (`checkContinuous(mode, in: Self.self)`) lets the census
// record it, and a local check then runs that one suite instead of the whole test target.

/// The test suite hosting a spec's continuous run, in the form `xcodebuild -only-testing:` selects
/// it once prefixed with the test target: `CartContinuousTests`, or `Outer/Inner` when nested.
public struct ContinuousSuite: Codable, Equatable, Sendable {
    /// The suite's type path inside its test target, one component per nesting level, `/`-separated.
    public let path: String

    /// Creates the suite identity of `type`, or fails when `type` has no name `xcodebuild` can
    /// select — a generic, private, or function-local type.
    ///
    /// - Parameter type: A test suite type, such as the type of `CartContinuousTests`.
    public init?(_ type: Any.Type) {
        let components = String(reflecting: type).split(separator: ".").dropFirst()
        guard !components.isEmpty,
              components.allSatisfy({ !$0.contains("(") && !$0.contains("<") && !$0.contains(" ") }) else {
            return nil
        }
        path = components.joined(separator: "/")
    }

    /// Creates a suite identity from a path already in `xcodebuild` form.
    ///
    /// - Parameter path: A `/`-separated type path, e.g. `CartContinuousTests`.
    public init(path: String) {
        self.path = path
    }
}

/// What a census run writes for each declared spec: its name, and the suite hosting it when that
/// suite named itself.
public struct CensusMarker: Codable, Equatable, Sendable {
    /// The spec's name.
    public let spec: String
    /// The hosting suite, or `nil` when the suite called `checkContinuous` without `in:`.
    public let suite: ContinuousSuite?

    /// The file-name suffix of a marker: `<spec>.census.json`.
    public static let fileSuffix = ".census.json"

    /// Creates a marker.
    ///
    /// - Parameters:
    ///   - spec: The spec's name.
    ///   - suite: The hosting suite, or `nil` when unknown.
    public init(spec: String, suite: ContinuousSuite?) {
        self.spec = spec
        self.suite = suite
    }

    /// Returns every marker a census wrote into `directory`, sorted by spec.
    ///
    /// - Parameter directory: A census run's results directory.
    /// - Returns: The markers; empty when the directory is missing or holds none. A marker without a
    ///   readable body still names its spec, from its file name.
    public static func read(from directory: URL) -> [CensusMarker] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(fileSuffix) }.sorted().map { file in
            let url = directory.appendingPathComponent(file)
            if let data = try? Data(contentsOf: url), let marker = try? JSONDecoder().decode(Self.self, from: data) {
                return marker
            }
            return CensusMarker(spec: String(file.dropLast(fileSuffix.count)), suite: nil)
        }
    }
}
