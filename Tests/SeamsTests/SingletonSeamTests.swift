@testable import HaruspecCore
@testable import HaruspecSeams
import XCTest

// The two un-injected mechanisms for singletons that a macro can't reach.

// MARK: - Fixture 1 — an ObjC-dispatched custom singleton (swizzle path)

/// Stands in for a legacy ObjC singleton: `NSObject`, an `@objc dynamic` method, and a `static let
/// shared` (immutable). This is the flavor where neither a Swift macro nor a `.shared` swap works — but
/// swizzling does, because the method is ObjC-dispatched.
final class LegacyDeviceManager: NSObject {
    nonisolated(unsafe) static let shared = LegacyDeviceManager()
    @objc dynamic func deviceToken() -> String {
        UUID().uuidString
    } // un-injected nondeterminism
}

extension LegacyDeviceManager {
    /// The paired swizzle target (harness code — would live behind `#if DEBUG`). After the exchange,
    /// calling ``seam_deviceToken()`` reaches the *original* `deviceToken` implementation.
    ///
    /// - Returns: The device token: inside a capture, the cassette's answer, which records the original
    ///   implementation's token or replays the recorded one and is empty when it holds no string;
    ///   outside one, the original implementation's.
    ///
    /// `dynamic` is essential: it forces the internal call through objc dispatch (the swapped
    /// selector), so it hits the original rather than statically recursing into this body.
    @objc dynamic func seam_deviceToken() -> String {
        guard let cassette = Seam.cassette else { return seam_deviceToken() }
        return cassette.string(seam: "swizzle.deviceToken", live: { self.seam_deviceToken() }) ?? ""
    }
}

// MARK: - Fixture 2 — a pure-Swift singleton with a settable `.shared` (proxy-swap path)

/// A common legacy shape: a settable `static var shared` and a non-`final` (overridable) method.
class LegacySessionManager {
    nonisolated(unsafe) static var shared = LegacySessionManager()
    func token() -> String {
        UUID().uuidString
    }
}

/// A recording/replaying decorator swapped into `.shared`. The call-site
/// `LegacySessionManager.shared.token()` is untouched; only the global is redirected (harness setup).
final class RecordingSessionManager: LegacySessionManager {
    private let cassette: Cassette
    init(_ cassette: Cassette) {
        self.cassette = cassette; super.init()
    }

    override func token() -> String {
        cassette.string(seam: "session.token", live: { super.token() }) ?? ""
    }
}

final class SingletonSeamTests: XCTestCase {
    /// Swizzle once for the whole process; unbound it passes through, so leaving it installed is inert.
    private static let swizzled: Bool = SeamSwizzle.exchange(
        LegacyDeviceManager.self,
        #selector(LegacyDeviceManager.deviceToken),
        with: #selector(LegacyDeviceManager.seam_deviceToken)
    )

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Self.swizzled, "the @objc dynamic method should be swizzlable")
    }

    /// ObjC/swizzle path: a bare `LegacyDeviceManager.shared.deviceToken()` — no DI, no macro, a
    /// `static let shared` — records and replays through the cassette.
    func testSwizzledObjCSingletonRecordsAndReplays() {
        let recording = Cassette()
        let golden = Seam.bind(recording) { LegacyDeviceManager.shared.deviceToken() }
        let data = recording.snapshot()

        let replay = Seam.bind(Cassette(replaying: data)) { LegacyDeviceManager.shared.deviceToken() }
        XCTAssertEqual(replay, golden, "the swizzled ObjC singleton method replays through the cassette")
    }

    func testSwizzledSingletonPassesThroughWhenUnbound() {
        XCTAssertNotEqual(
            LegacyDeviceManager.shared.deviceToken(),
            LegacyDeviceManager.shared.deviceToken(),
            "with no cassette bound the swizzled method is live — production behavior unchanged"
        )
    }

    /// Pure-Swift path: swap `.shared` to a recording decorator; the call-site stays untouched.
    func testSharedSwapProxyRecordsAndReplays() {
        let original = LegacySessionManager.shared
        defer { LegacySessionManager.shared = original }

        let recording = Cassette()
        LegacySessionManager.shared = RecordingSessionManager(recording)
        let golden = LegacySessionManager.shared.token()
        let data = recording.snapshot()

        LegacySessionManager.shared = RecordingSessionManager(Cassette(replaying: data))
        XCTAssertEqual(
            LegacySessionManager.shared.token(),
            golden,
            "the .shared decorator replays through the cassette"
        )
    }
}
