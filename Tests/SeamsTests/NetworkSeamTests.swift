@testable import HaruspecCore
@testable import HaruspecSeams
import XCTest

/// The network seam end-to-end through a real `URLSession`: record from a stand-in live source, then
/// replay the recorded response **offline** — no live handler, no network — which is exactly what a
/// headless CI replay looks like.
final class NetworkSeamTests: XCTestCase {
    private let url = URL(string: "https://api.example.com/checkout")!

    private func fetch(_ session: URLSession) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    func testRecordThenReplayOffline() async throws {
        let goldenBody = Data(#"{"total":2525}"#.utf8)

        // Record: the live handler stands in for the real server.
        let recording = Cassette()
        let recSession = URLSession(configuration: CassetteURLProtocol.install(
            cassette: recording,
            liveHandler: { _ in (200, goldenBody) }
        ))
        let recorded = try await fetch(recSession)
        XCTAssertEqual(recorded.status, 200)
        XCTAssertEqual(recorded.body, goldenBody)
        let cassetteData = recording.snapshot()

        // Replay: no live handler at all — the response comes purely from the cassette.
        let replaySession = URLSession(configuration: CassetteURLProtocol.install(
            cassette: Cassette(replaying: cassetteData)
        ))
        let replayed = try await fetch(replaySession)
        XCTAssertEqual(replayed.status, 200)
        XCTAssertEqual(replayed.body, goldenBody, "the recorded body is served with no network")
    }

    func testUnrecordedRequestSurfacesAsMiss() async {
        // A replay cassette with nothing recorded for this URL.
        let empty = Cassette(replaying: CassetteData(tracks: [:]))
        let session = URLSession(configuration: CassetteURLProtocol.install(cassette: empty))
        _ = try? await fetch(session)
        XCTAssertEqual(
            empty.misses.map(\.seam),
            ["url:GET \(url.absoluteString)"],
            "an unrecorded request is surfaced, not fabricated"
        )
    }
}
