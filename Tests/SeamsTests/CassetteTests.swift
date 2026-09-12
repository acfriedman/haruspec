@testable import HaruspecCore
@testable import HaruspecSeams
import XCTest

final class CassetteTests: XCTestCase {
    func testTypedAccessorsRoundTrip() {
        let rec = Cassette()
        XCTAssertEqual(rec.int(seam: "i", live: { 7 }), 7)
        XCTAssertEqual(rec.double(seam: "d", live: { 3.5 }), 3.5)
        XCTAssertEqual(rec.bool(seam: "b", live: { true }), true)
        XCTAssertEqual(rec.string(seam: "s", live: { "hi" }), "hi")
        XCTAssertEqual(rec.data(seam: "bin", live: { Data([1, 2, 3]) }), Data([1, 2, 3]))
        let data = rec.snapshot()

        let play = Cassette(replaying: data)
        XCTAssertEqual(play.int(seam: "i", live: { 999 }), 7, "replay ignores live and returns the recorded value")
        XCTAssertEqual(play.double(seam: "d", live: { 0 }), 3.5)
        XCTAssertEqual(play.bool(seam: "b", live: { false }), true)
        XCTAssertEqual(play.string(seam: "s", live: { "x" }), "hi")
        XCTAssertEqual(play.data(seam: "bin", live: { Data() }), Data([1, 2, 3]))
    }

    func testNilStringRoundTrips() {
        let rec = Cassette()
        XCTAssertNil(rec.string(seam: "s", live: { nil }))
        let play = Cassette(replaying: rec.snapshot())
        XCTAssertNil(play.string(seam: "s", live: { "x" }), "recorded nil replays as nil, not the live value")
    }

    func testOrderPreservedPerSeam() {
        let rec = Cassette()
        _ = rec.int(seam: "k", live: { 1 })
        _ = rec.int(seam: "k", live: { 2 })
        let play = Cassette(replaying: rec.snapshot())
        XCTAssertEqual(play.int(seam: "k", live: { 0 }), 1)
        XCTAssertEqual(play.int(seam: "k", live: { 0 }), 2)
    }

    func testUnrecordedInteractionSurfacesAsMiss() {
        let rec = Cassette()
        _ = rec.double(seam: "clock", live: { 1.0 }) // record exactly one reading
        let play = Cassette(replaying: rec.snapshot())
        _ = play.double(seam: "clock", live: { 99 }) // hit
        _ = play.double(seam: "clock", live: { 99 }) // miss — recording exhausted
        XCTAssertEqual(play.misses, [SeamMiss(seam: "clock", ordinal: 1)])
    }

    func testJSONRoundTrip() throws {
        let rec = Cassette()
        _ = rec.int(seam: "i", live: { 42 })
        _ = rec.string(seam: "s", live: { "a" })
        let snapshot = rec.snapshot()
        XCTAssertEqual(try CassetteData(jsonData: snapshot.jsonData()), snapshot)
    }

    func testARecordingCanPreferAValueOverTheLiveRead() {
        // The golden template is recorded this way: a declared seam answers with its domain's
        // interior value and records it; an undeclared seam still reads live.
        let cassette = Cassette(recordingPreferring: ["qty": .int(5)])

        XCTAssertEqual(cassette.int(seam: "qty", live: { 0 }), 5)
        XCTAssertEqual(cassette.int(seam: "other", live: { 42 }), 42)
        XCTAssertEqual(cassette.snapshot().tracks, ["qty": [.int(5)], "other": [.int(42)]])
    }
}
