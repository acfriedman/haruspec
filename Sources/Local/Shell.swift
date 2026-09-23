import Foundation

/// A finished child process: its exit status and what it wrote.
struct ShellResult {
    /// The process's exit status; zero is success.
    let status: Int32
    /// Standard output, or empty when output went to a log file.
    let stdout: String
    /// Standard error, or empty when output went to a log file.
    let stderr: String
}

/// Runs child processes for the local check, so no child writes to this process's stdout — the MCP
/// server's stdout is its protocol channel.
enum Shell {
    /// Runs `arguments` through `/usr/bin/env` and returns its output once it exits.
    ///
    /// - Parameters:
    ///   - arguments: The command and its arguments, e.g. `["git", "rev-parse", "HEAD"]`.
    ///   - directory: The working directory; `nil` inherits this process's.
    ///   - environment: The complete child environment; `nil` inherits this process's.
    ///   - log: A file that receives both output streams instead of capturing them; `nil` captures.
    /// - Returns: The exit status and, when not logging, both output streams.
    /// - Throws: A launch error when the command cannot start.
    static func run(
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        log: URL? = nil
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            return ShellResult(status: process.terminationStatus, stdout: "", stderr: "")
        }
        // Standard error goes to a file rather than a second pipe: draining two pipes from one
        // thread deadlocks once the undrained one fills.
        let errorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("haruspec-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = errorHandle
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? errorHandle.close()
        let errors = (try? Data(contentsOf: errorFile)) ?? Data()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(bytes: data, encoding: .utf8) ?? "",
            stderr: String(bytes: errors, encoding: .utf8) ?? ""
        )
    }
}

extension FileManager {
    /// Creates the directory that will hold `file`, with any missing intermediates.
    ///
    /// - Parameter file: A file path whose parent may not exist yet.
    /// - Throws: A file-system error when the directory cannot be created.
    func createParentDirectory(of file: URL) throws {
        try createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}
