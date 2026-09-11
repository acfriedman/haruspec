import Foundation
import HaruspecCore
@testable import HaruspecTrace
import XCTest

// `MainActor.run` is claimed by overload preference (`resultType:` is defaulted in the standard
// form), so a subject that delivers an announcement this way is seen delivering it on `main` — the
// hop is the runtime's own enqueue, invisible to every other seam.

final class MainActorSeamTests: XCTestCase {
    private func capture(_ body: (RecordingNotificationCenter) async -> Void) async -> [TraceEvent] {
        let recorder = TraceRecorder(name: "t")
        let center = RecordingNotificationCenter()
        await TraceContext.$current.withValue(recorder) { await body(center) }
        return recorder.trace().events
    }

    /// An announcement delivered through `MainActor.run` resolves to `main`, and the value comes back.
    func testAnAnnouncementDeliveredThroughMainActorRunIsOnMain() async {
        let events = await capture { center in
            let delivered = await MainActor.run {
                center.post(name: .init("DidFinish"), object: nil)
                return 42
            }
            XCTAssertEqual(delivered, 42)
        }

        XCTAssertEqual(events.map(\.label), ["DidFinish"])
        XCTAssertEqual(events.map(\.domain), [.main])
    }

    /// The claim is by overload, so a throwing body keeps its `rethrows` contract.
    func testAThrowingBodyRethrows() async {
        struct Refused: Error {}
        let events = await capture { center in
            do {
                try await MainActor.run {
                    center.post(name: .init("Attempted"), object: nil)
                    throw Refused()
                }
                XCTFail("expected the body's error")
            } catch {
                XCTAssertTrue(error is Refused)
            }
        }

        XCTAssertEqual(events.map(\.domain), [.main])
    }

    /// Being on the main thread without having been handed work there is a fact about the caller,
    /// not the subject — the standard `resultType:` form makes the same hop unclaimed, and an
    /// announcement from it stays `ambient`.
    func testAnUnmarkedMainThreadContextStaysAmbient() async {
        let events = await capture { center in
            await MainActor.run(resultType: Void.self) {
                center.post(name: .init("DidFinish"), object: nil)
            }
        }

        XCTAssertEqual(events.map(\.domain), [.ambient])
    }
}
