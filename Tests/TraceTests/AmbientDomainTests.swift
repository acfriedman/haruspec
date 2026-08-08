import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// A domain is supposed to describe *the code*: "this is MainActor-isolated", "this runs on the cart
/// queue". For code that declares no isolation at all, there is no such fact — and today the resolver
/// answers with wherever the caller happened to be, which makes the harness part of the measurement.
///
/// That is the same failure `worker-N` had, one level up: a field meant to remove scheduling
/// nondeterminism, reintroducing it.
final class AmbientDomainTests: XCTestCase {
    /// A subject that declares nothing. `MainActor.run` would not do here — that closure genuinely
    /// *is* isolated, and `.main` would be the right answer for it.
    private nonisolated static func record(into recorder: TraceRecorder) {
        TraceContext.$current.withValue(recorder) { Haruspec.marker("work") }
    }

    /// Identical work, two calling contexts. Nothing about the subject differs, so nothing about its
    /// recorded domain should either.
    func testUnisolatedWorkRecordsTheSameDomainFromAnyCaller() async {
        let fromMain = TraceRecorder(name: "from-main")
        await MainActor.run { Self.record(into: fromMain) }

        let fromPool = TraceRecorder(name: "from-pool")
        await Task.detached { Self.record(into: fromPool) }.value

        XCTAssertEqual(
            fromMain.trace().events.first?.domain,
            fromPool.trace().events.first?.domain,
            "the subject declares no isolation, so its domain must not depend on who called it"
        )
        XCTAssertEqual(fromMain.trace().events.first?.domain, .ambient)
    }
}
