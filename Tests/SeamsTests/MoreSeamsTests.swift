@testable import HaruspecCore
@testable import HaruspecSeams
import XCTest

/// The remaining value seams (environment, keychain, files): record once, replay identically even when
/// the live source has moved on — proving the boundary is genuinely pinned.
final class MoreSeamsTests: XCTestCase {
    func testEnvironmentReplaysRecordedLocaleAndTimeZone() {
        let rec = Cassette()
        let env = SeamEnvironment(cassette: rec)
        XCTAssertEqual(env.localeIdentifier(live: { "en_US" }), "en_US")
        XCTAssertEqual(env.timeZoneIdentifier(live: { "America/New_York" }), "America/New_York")

        let play = SeamEnvironment(cassette: Cassette(replaying: rec.snapshot()))
        XCTAssertEqual(play.localeIdentifier(live: { "fr_FR" }), "en_US", "replay returns the recorded locale")
        XCTAssertEqual(play.timeZoneIdentifier(live: { "Europe/Paris" }), "America/New_York")
    }

    func testKeychainRecordsTokenAndReplaysItOffline() {
        let rec = Cassette()
        let keychain = SeamKeychain(cassette: rec)
        XCTAssertEqual(keychain.value(forKey: "authToken", live: { "secret-abc" }), "secret-abc")

        // Replay with a live source that would return nil (e.g. no keychain in CI) — still gets the token.
        let play = SeamKeychain(cassette: Cassette(replaying: rec.snapshot()))
        XCTAssertEqual(play.value(forKey: "authToken", live: { nil }), "secret-abc",
                       "the recorded token replays, so an auth gate never blocks a headless run")
    }

    func testKeychainReadYourWrites() {
        let keychain = SeamKeychain(cassette: Cassette())
        keychain.set("fresh", forKey: "authToken")
        XCTAssertEqual(keychain.value(forKey: "authToken", live: { "stale" }), "fresh")
    }

    func testFileReadsReplayAndWritesAreSandboxed() {
        let rec = Cassette()
        let fileSystem = SeamFileSystem(cassette: rec)
        let golden = Data("config=on".utf8)
        XCTAssertEqual(fileSystem.readData(atPath: "/etc/app.conf", live: { golden }), golden)

        let play = SeamFileSystem(cassette: Cassette(replaying: rec.snapshot()))
        XCTAssertEqual(play.readData(atPath: "/etc/app.conf", live: { Data() }), golden, "recorded read replays")

        // Writes stay in memory and read back within the run; nothing hits disk.
        play.write(Data("config=off".utf8), toPath: "/etc/app.conf")
        XCTAssertEqual(play.readData(atPath: "/etc/app.conf", live: { Data() }), Data("config=off".utf8))
        XCTAssertEqual(play.recordedWrites()["/etc/app.conf"], Data("config=off".utf8))
    }
}
