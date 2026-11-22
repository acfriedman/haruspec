import Foundation

/// `haruspec init`: opts a repository in to the local check by writing the launcher and a
/// configuration detected from the project.
public enum LocalSetup {
    /// Writes `.haruspec/bin/haruspec` (always, so it tracks the engine) and, when the repository
    /// has none, `.haruspec/config.json` detected from its Xcode project.
    ///
    /// - Parameter path: Any directory inside the repository.
    /// - Returns: One line per thing written or kept, then the next steps.
    /// - Throws: ``LocalCheckError/notARepository(_:)`` outside a git repository;
    ///   ``LocalCheckError/invalidConfig(_:)`` when an existing configuration is invalid or no single
    ///   project or workspace can be chosen; file-system errors writing either file.
    public static func initialize(at path: URL) throws -> [String] {
        let directory = try HaruspecDirectory(repositoryRoot: Git(directory: path).topLevel())
        var lines = try [writeLauncher(in: directory)]
        if FileManager.default.fileExists(atPath: directory.config.path) {
            _ = try LocalConfig.load(from: directory.config)
            lines.append("kept .haruspec/\(LocalConfig.fileName) (valid)")
        } else {
            let config = try detectedConfig(in: directory.repositoryRoot)
            try Data(render(config).utf8).write(to: directory.config)
            _ = try LocalConfig.load(from: directory.config)
            lines.append("wrote .haruspec/\(LocalConfig.fileName) — check the guesses:\n" + render(config))
        }
        lines.append("""
        next:
          1. give each continuous suite its name, so a check runs only that suite:
               try await MySpec().checkContinuous(mode, in: Self.self)
          2. commit .haruspec/config.json and .haruspec/bin/haruspec
          3. on a branch: .haruspec/bin/haruspec check
        """)
        return lines
    }

    private static func writeLauncher(in directory: HaruspecDirectory) throws -> String {
        let url = directory.root.appendingPathComponent(launcherPath)
        let text = LauncherScript.text + "\n"
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != text else {
            return "kept .haruspec/\(launcherPath) (current)"
        }
        try FileManager.default.createParentDirectory(of: url)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return "\(existing == nil ? "wrote" : "updated") .haruspec/\(launcherPath)"
    }

    /// Returns a configuration for the repository's one Xcode project or workspace.
    ///
    /// - Parameter root: The repository root.
    /// - Returns: The detected configuration: the scheme named like the project, its `Tests` target,
    ///   and the first available iPhone simulator.
    /// - Throws: ``LocalCheckError/invalidConfig(_:)`` when the root holds no project or workspace,
    ///   or several, and a launch error when `xcodebuild` cannot start.
    static func detectedConfig(in root: URL) throws -> LocalConfig {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        let workspaces = names.filter { $0.hasSuffix(".xcworkspace") }
        let projects = names.filter { $0.hasSuffix(".xcodeproj") }
        let (flag, container): (String, String)
        if workspaces.count == 1 {
            (flag, container) = ("-workspace", workspaces[0])
        } else if workspaces.isEmpty, projects.count == 1 {
            (flag, container) = ("-project", projects[0])
        } else {
            throw LocalCheckError.invalidConfig(
                "cannot pick one project or workspace at the repository root (found "
                    + "\((workspaces + projects).joined(separator: ", "))) — write .haruspec/config.json by hand:\n\n"
                    + LocalConfig.example
            )
        }
        let listing = try Shell.run(["xcodebuild", "-list", "-json", flag, container], in: root)
        let json = (try? JSONSerialization.jsonObject(with: Data(listing.stdout.utf8))) as? [String: Any]
        let info = (json?["project"] ?? json?["workspace"]) as? [String: Any] ?? [:]
        let stem = (container as NSString).deletingPathExtension
        let schemes = info["schemes"] as? [String] ?? []
        let scheme = schemes.contains(stem) ? stem : schemes.first ?? stem
        let targets = info["targets"] as? [String] ?? []
        let testTarget = targets.contains("\(scheme)Tests")
            ? "\(scheme)Tests"
            : targets.first { $0.hasSuffix("Tests") && !$0.hasSuffix("UITests") } ?? "\(scheme)Tests"
        return try LocalConfig(
            project: flag == "-project" ? container : nil,
            workspace: flag == "-workspace" ? container : nil,
            scheme: scheme,
            destination: "platform=iOS Simulator,name=\(firstIPhone() ?? "iPhone 17")",
            testTarget: testTarget
        )
    }

    /// Returns the name of an available iPhone simulator on the newest installed iOS runtime.
    ///
    /// - Returns: The device name, or `nil` when `simctl` lists none.
    /// - Throws: A launch error when `simctl` cannot start.
    private static func firstIPhone() throws -> String? {
        let listing = try Shell.run(["xcrun", "simctl", "list", "devices", "available", "-j"])
        guard let json = (try? JSONSerialization.jsonObject(with: Data(listing.stdout.utf8))) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }
        let runtimes = devices.keys.filter { $0.contains("iOS") }.sorted {
            $0.compare($1, options: .numeric) == .orderedDescending
        }
        for runtime in runtimes {
            let names = devices[runtime]?.compactMap { $0["name"] as? String } ?? []
            if let name = names.first(where: { $0.hasPrefix("iPhone") }) {
                return name
            }
        }
        return nil
    }

    private static func render(_ config: LocalConfig) -> String {
        let container = config.project.map { "\"project\": \"\($0)\"" }
            ?? config.workspace.map { "\"workspace\": \"\($0)\"" } ?? ""
        return """
        {
          \(container),
          "scheme": "\(config.scheme)",
          "destination": "\(config.destination)",
          "testTarget": "\(config.testTarget)"
        }

        """
    }

    /// The launcher's path under `.haruspec/`.
    static let launcherPath = "bin/haruspec"
}
