import XCTest

/// `XCTAssertThrowsError` takes a *synchronous* autoclosure, so it cannot hold an `await`. An
/// autoclosure may itself be `async`, which is all this needs to be the async twin.
///
/// Everything else in these tests hoists the awaited value to a `let` and asserts on that; only the
/// throwing form genuinely needs a helper, because the expression has to stay unevaluated until the
/// `do` block runs it.
func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: String = "expected an error, none was thrown",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        handler(error)
    }
}
