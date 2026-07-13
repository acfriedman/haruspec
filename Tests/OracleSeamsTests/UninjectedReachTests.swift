import XCTest
@testable import OracleCore
@testable import OracleSeams
import OracleMacros

/// Un-injected reach: the harness controls nondeterminism that legacy code reads **without any
/// dependency injection**. `LegacySession` calls bare `Date()` / `UUID()` directly — no constructor
/// parameter, no protocol, no seam handed in — and `@Seamed` rewrites those call-sites (under
/// `#if DEBUG`) to route through the ambient `OracleSeam` cassette. This is the mechanism that lets the
/// seam harness reach real legacy code, which never has clean DI.
@Seamed
final class LegacySession {
    func fingerprint() -> [String] {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let id = UUID().uuidString
        return ["\(millis)", id]
    }
}

final class UninjectedReachTests: XCTestCase {

    func testBareDateAndUUIDReplayThroughCassette() {
        let service = LegacySession()

        // Record a golden run — the bare Date()/UUID() are captured because @Seamed routed them.
        let recording = Cassette()
        let golden = OracleSeam.bind(recording) { service.fingerprint() }
        let data = recording.snapshot()

        // Replay: identical output across runs, even though the code has no injected seam.
        let replay1 = OracleSeam.bind(Cassette(replaying: data)) { service.fingerprint() }
        let replay2 = OracleSeam.bind(Cassette(replaying: data)) { service.fingerprint() }
        XCTAssertEqual(replay1, golden, "bare Date()/UUID() replay identically through the cassette")
        XCTAssertEqual(replay1, replay2)
    }

    func testUnboundIsLivePassthrough() {
        let service = LegacySession()
        // With no cassette bound, the rewritten calls pass through to the real Date()/UUID(): the code
        // behaves exactly as it did before — the fresh UUID alone guarantees two runs differ.
        XCTAssertNotEqual(service.fingerprint(), service.fingerprint(),
                          "outside a binding, bare calls stay live and nondeterministic")
    }

    func testRecordedTranscriptSurvivesReload() throws {
        let service = LegacySession()
        let recording = Cassette()
        let golden = OracleSeam.bind(recording) { service.fingerprint() }
        let reloaded = try CassetteData(jsonData: recording.snapshot().jsonData())
        XCTAssertEqual(OracleSeam.bind(Cassette(replaying: reloaded)) { service.fingerprint() }, golden)
    }
}
