import XCTest

/// The async twin of `XCTAssertThrowsError`, whose autoclosure is synchronous and so cannot hold an
/// `await`.
///
/// - Parameters:
///   - message: The failure message for when nothing is thrown.
///   - file: The file of the calling assertion, defaulted at the call site.
///   - line: The line of the calling assertion, defaulted at the call site.
///   - expression: The async work expected to throw.
///   - handler: Inspects the thrown error; the default ignores it.
///
/// Takes an ordinary closure rather than an `@autoclosure`, even though an autoclosure may itself be
/// `async` and would read closer to the XCTest original. SwiftFormat cannot see that such a parameter
/// is async and strips the `await` inside it as redundant, which then fails to compile — a formatter
/// that silently breaks the build is worse than a slightly wordier call site.
func XCTAssertThrowsErrorAsync(
    _ message: String = "expected an error, none was thrown",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> some Any,
    handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        handler(error)
    }
}
