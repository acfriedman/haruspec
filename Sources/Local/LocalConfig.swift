import Foundation

// `.haruspec/config.json` — the six values that make a repository's test run drivable from outside
// Xcode. Its presence is the opt-in: without it `haruspec check` refuses and prints the file to write.

/// How `haruspec check` builds and tests the repository, read from `.haruspec/config.json`.
///
/// Decoding is strict: an unknown key is an error rather than a silently ignored setting, and the
/// project and workspace are mutually exclusive.
public struct LocalConfig: Codable, Equatable, Sendable {
    /// Repo-relative path to the `.xcodeproj`; exactly one of `project` and `workspace` is set.
    public var project: String?
    /// Repo-relative path to the `.xcworkspace`; exactly one of `project` and `workspace` is set.
    public var workspace: String?
    /// The scheme whose test action includes ``testTarget``.
    public var scheme: String
    /// An `xcodebuild -destination` specifier, e.g. `platform=iOS Simulator,name=iPhone 17`.
    public var destination: String
    /// The unit-test target that links the specs; the whole target runs, never a single test.
    public var testTarget: String
    /// The build configuration; `nil` means `Debug`, the only configuration the harness runs in.
    public var configuration: String?
    /// The branch a check compares against; `nil` means `main`.
    public var base: String?
    /// The specs to check; `nil` means every spec the test target declares.
    public var specs: [String]?

    /// The file name under `.haruspec/`.
    public static let fileName = "config.json"

    /// The build configuration a check runs, defaulted.
    public var resolvedConfiguration: String {
        configuration ?? "Debug"
    }

    /// The base branch a check compares against, defaulted.
    public var resolvedBase: String {
        base ?? "main"
    }

    /// Creates a configuration from its values.
    ///
    /// - Parameters:
    ///   - project: Repo-relative `.xcodeproj` path, or `nil` when `workspace` is set.
    ///   - workspace: Repo-relative `.xcworkspace` path, or `nil` when `project` is set.
    ///   - scheme: The scheme to test.
    ///   - destination: An `xcodebuild -destination` specifier.
    ///   - testTarget: The unit-test target that links the specs.
    ///   - configuration: The build configuration; `nil` means `Debug`.
    ///   - base: The branch to compare against; `nil` means `main`.
    ///   - specs: The specs to check; `nil` means every declared spec.
    public init(
        project: String? = nil,
        workspace: String? = nil,
        scheme: String,
        destination: String,
        testTarget: String,
        configuration: String? = nil,
        base: String? = nil,
        specs: [String]? = nil
    ) {
        self.project = project
        self.workspace = workspace
        self.scheme = scheme
        self.destination = destination
        self.testTarget = testTarget
        self.configuration = configuration
        self.base = base
        self.specs = specs
    }

    /// Reads and validates the configuration at `url`.
    ///
    /// - Parameter url: The `config.json` file.
    /// - Returns: The validated configuration.
    /// - Throws: ``LocalCheckError/missingConfig(_:)`` when the file does not exist, and
    ///   ``LocalCheckError/invalidConfig(_:)`` when it does not decode or fails validation.
    public static func load(from url: URL) throws -> LocalConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalCheckError.missingConfig(url.path)
        }
        let data = try Data(contentsOf: url)
        let config: LocalConfig
        do {
            try rejectUnknownKeys(in: data)
            config = try JSONDecoder().decode(LocalConfig.self, from: data)
        } catch let error as LocalCheckError {
            throw error
        } catch {
            throw LocalCheckError.invalidConfig("\(url.path) does not decode: \(error)")
        }
        try config.validate()
        return config
    }

    /// Checks the cross-field rules decoding cannot express.
    ///
    /// - Throws: ``LocalCheckError/invalidConfig(_:)`` naming the first broken rule.
    public func validate() throws {
        switch (project, workspace) {
        case (nil, nil):
            throw LocalCheckError.invalidConfig("set \"project\" (an .xcodeproj) or \"workspace\" (an .xcworkspace)")
        case (.some, .some):
            throw LocalCheckError.invalidConfig("set \"project\" or \"workspace\", not both")
        default:
            break
        }
        for (key, value) in [("scheme", scheme), ("destination", destination), ("testTarget", testTarget)]
            where value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LocalCheckError.invalidConfig("\"\(key)\" is empty")
        }
        if let specs, specs.isEmpty {
            throw LocalCheckError.invalidConfig(
                "\"specs\" is empty — list the specs to check, or remove the key to check every declared spec"
            )
        }
    }

    /// The configuration to show a repository that has none: the example `haruspec check` prints.
    public static let example = """
    {
      "project": "MyApp.xcodeproj",
      "scheme": "MyApp",
      "destination": "platform=iOS Simulator,name=iPhone 17",
      "testTarget": "MyAppTests"
    }
    """

    private static let knownKeys: Set<String> = [
        "project",
        "workspace",
        "scheme",
        "destination",
        "testTarget",
        "configuration",
        "base",
        "specs"
    ]

    private static func rejectUnknownKeys(in data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalCheckError.invalidConfig("the file must hold one JSON object")
        }
        let unknown = Set(object.keys).subtracting(knownKeys).sorted()
        guard unknown.isEmpty else {
            throw LocalCheckError.invalidConfig(
                "unknown key\(unknown.count == 1 ? "" : "s") \(unknown.map { "\"\($0)\"" }.joined(separator: ", "))"
                    + " — known keys: \(knownKeys.sorted().joined(separator: ", "))"
            )
        }
    }
}
