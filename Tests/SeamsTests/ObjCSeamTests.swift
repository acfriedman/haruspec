@testable import HaruspecCore
@testable import HaruspecSeams
import LegacyObjC
import XCTest

/// The swizzle seam against a **genuine Objective-C singleton** (`LegacyObjC/LegacyObjCManager.m`) — the
/// case the earlier `SingletonSeamTests` only *simulated* with a Swift `@objc dynamic` fixture. The
/// point: the ObjC method `deviceToken` carries **no annotation at all** and is still swizzlable,
/// because ObjC dispatches through `objc_msgSend` by nature. This is why "ObjC is the easy case."
extension LegacyObjCManager {
    /// Returns the device token through the `objc.deviceToken` seam: the paired swizzle target (harness
    /// code — would be `#if DEBUG`).
    ///
    /// - Returns: The token the installed cassette replays or records, or the original token when no
    ///   cassette is installed; empty when the cassette yields no string.
    ///
    /// `dynamic` is still needed on *this* Swift method so its internal self-call goes through objc
    /// dispatch to the original; the original ObjC `deviceToken` needed nothing.
    @objc dynamic func seam_deviceToken() -> String {
        guard let cassette = Seam.cassette else { return seam_deviceToken() }
        return cassette.string(seam: "objc.deviceToken", live: { self.seam_deviceToken() }) ?? ""
    }
}

final class ObjCSeamTests: XCTestCase {
    private static let swizzled: Bool = SeamSwizzle.exchange(
        LegacyObjCManager.self,
        #selector(LegacyObjCManager.deviceToken),
        with: #selector(LegacyObjCManager.seam_deviceToken)
    )

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Self.swizzled, "a genuine ObjC method is swizzlable with no annotation")
    }

    /// A bare `LegacyObjCManager.shared.deviceToken()` — real ObjC, `dispatch_once` singleton, no DI,
    /// no macro — records and replays through the cassette.
    func testRealObjCSingletonRecordsAndReplays() {
        let recording = Cassette()
        let golden = Seam.bind(recording) { LegacyObjCManager.shared.deviceToken() }
        let data = recording.snapshot()

        let replay = Seam.bind(Cassette(replaying: data)) { LegacyObjCManager.shared.deviceToken() }
        XCTAssertEqual(replay, golden, "the swizzled ObjC method replays through the cassette")
    }

    func testRealObjCSingletonPassesThroughWhenUnbound() {
        XCTAssertNotEqual(
            LegacyObjCManager.shared.deviceToken(),
            LegacyObjCManager.shared.deviceToken(),
            "unbound, the swizzled ObjC method is live — production behavior unchanged"
        )
    }
}
