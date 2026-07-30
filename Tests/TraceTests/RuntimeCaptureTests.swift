import XCTest
import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace

final class RuntimeValueTests: XCTestCase {
    func testDisambiguatesBridgedNumbers() {
        // The classic trap: a bridged Int must not be read as a Bool.
        XCTAssertEqual(RuntimeValue.canonical(5), .int(5))
        XCTAssertEqual(RuntimeValue.canonical(true), .bool(true))
        XCTAssertEqual(RuntimeValue.canonical(1.5), .double(1.5))
        XCTAssertEqual(RuntimeValue.canonical("x"), .string("x"))
    }

    func testConvertsCollections() {
        XCTAssertEqual(RuntimeValue.canonical([1, 2, 3] as [Any]), [1, 2, 3])
        XCTAssertEqual(RuntimeValue.canonical(["a": 1, "b": "two"] as [String: Any]),
                       ["a": 1, "b": "two"])
    }

    // A non-Encodable Swift struct is canonicalized structurally by reflection — no `Codable`
    // conformance (and no hand-written DTO mirror) required to get a diffable payload.
    func testCanonicalizesNonEncodableStructByReflection() {
        struct Plain { let x = 1; let name = "a" }
        XCTAssertEqual(RuntimeValue.canonical(Plain()), ["x": 1, "name": "a"])
    }

    // A plain Obj-C object (no Encodable, no Codable mirror) is walked via its runtime property
    // list + KVC — this is the tax the reflection fallback deletes for migration authors.
    func testCanonicalizesObjCObjectByPropertyList() {
        let receipt = Receipt()
        receipt.orderID = "A-100"
        receipt.total = 42
        XCTAssertEqual(RuntimeValue.canonical(receipt), ["orderID": "A-100", "total": 42])
    }

    // Reflection recurses: nested objects and unwrapped optionals become nested structure.
    func testCanonicalizesNestedStructureAndUnwrapsOptionals() {
        struct Line { let sku = "X"; let qty = 2 }
        struct Order { let line = Line(); let note: String? = nil; let ref: Int? = 7 }
        XCTAssertEqual(RuntimeValue.canonical(Order()),
                       ["line": ["sku": "X", "qty": 2], "note": .null, "ref": 7])
    }

    func testStillFallsBackToDescriptionForStructurelessValues() {
        let closure: () -> Void = {}
        if case .string = RuntimeValue.canonical(closure) { /* ok */ } else {
            XCTFail("expected a string fallback for a value with no keyed structure")
        }
    }
}

/// A plain Obj-C-style object with no `Encodable`/`Codable` conformance, standing in for the
/// bridged `Receipt` a migration would return.
private final class Receipt: NSObject {
    @objc var orderID: String = ""
    @objc var total: Int = 0
}

final class NotificationInterceptorTests: XCTestCase {
    func testCapturesAllowlistedPostsAndFiltersOthers() {
        let recorder = TraceRecorder(name: "t")
        let center = NotificationCenter()
        let sut = NotificationInterceptor(recorder: recorder, center: center, names: ["Ping"])
        sut.start()
        center.post(name: Notification.Name("Ping"), object: nil, userInfo: ["n": 1])
        center.post(name: Notification.Name("Unlisted"), object: nil) // filtered
        sut.stop()

        let events = recorder.trace().events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .notification)
        XCTAssertEqual(events[0].label, "Ping")
        XCTAssertEqual(events[0].payload, ["n": 1])
    }

    func testStopEndsCapture() {
        let recorder = TraceRecorder(name: "t")
        let center = NotificationCenter()
        let sut = NotificationInterceptor(recorder: recorder, center: center, names: ["Ping"])
        sut.start()
        sut.stop()
        center.post(name: Notification.Name("Ping"), object: nil)
        XCTAssertTrue(recorder.trace().events.isEmpty)
    }

    func testPostsAreCapturedInOrderSynchronously() {
        let recorder = TraceRecorder(name: "t")
        let center = NotificationCenter()
        let sut = NotificationInterceptor(recorder: recorder, center: center, names: ["A", "B"])
        sut.start()
        center.post(name: Notification.Name("A"), object: nil)
        center.post(name: Notification.Name("B"), object: nil)
        sut.stop()
        XCTAssertEqual(recorder.trace().events.map(\.label), ["A", "B"])
    }

    /// Isolation is structural, not filtered: each capture window observes its *own* `NotificationCenter`,
    /// so a concurrent window's posts never reach it — even across threads. This is how the scenario runner
    /// keeps parallel windows disjoint (a fresh center per window, surfaced as `SeamContext.notifications`),
    /// replacing the old same-thread guard that papered over a *shared* `.default` center.
    func testSeparateCentersDoNotCrossPollinate() {
        let recorderA = TraceRecorder(name: "a")
        let recorderB = TraceRecorder(name: "b")
        let centerA = NotificationCenter()
        let centerB = NotificationCenter()
        let a = NotificationInterceptor(recorder: recorderA, center: centerA, names: ["Ping"])
        let b = NotificationInterceptor(recorder: recorderB, center: centerB, names: ["Ping"])
        a.start(); b.start()

        centerA.post(name: Notification.Name("Ping"), object: nil, userInfo: ["src": 1]) // only A observes centerA

        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            centerB.post(name: Notification.Name("Ping"), object: nil, userInfo: ["src": 2]) // only B observes centerB
            done.signal()
        }
        done.wait()

        a.stop(); b.stop()

        XCTAssertEqual(recorderA.trace().events.map(\.label), ["Ping"], "A's window sees only its own center")
        XCTAssertEqual(recorderA.trace().events.first?.payload, ["src": 1])
        XCTAssertEqual(recorderB.trace().events.map(\.label), ["Ping"], "B's window sees only its own center")
        XCTAssertEqual(recorderB.trace().events.first?.payload, ["src": 2])
    }
}

final class SemanticEventTests: XCTestCase {
    func testMarkerRecordsPayloadFreeSemanticTier() {
        let recorder = TraceRecorder(name: "t")
        TraceContext.$current.withValue(recorder) {
            Haruspec.marker("order_placed")
        }
        let events = recorder.trace().events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].tier, .semantic)
        XCTAssertEqual(events[0].kind, .marker)
        XCTAssertEqual(events[0].label, "order_placed")
        XCTAssertNil(events[0].payload, "markers are payload-free by design")
    }

    /// Observable side effects are the durable contract, so they belong to the semantic tier and
    /// survive `structuralComparison: .ignored`.
    func testNotificationsAndStateChangesAreSemantic() {
        let recorder = TraceRecorder(name: "t")
        recorder.notification("CartDidChange", payload: ["itemCount": 1])
        recorder.stateChange("total", value: 10)
        XCTAssertTrue(recorder.trace().events.allSatisfy { $0.tier == .semantic })
    }

    func testCallMechanicsAreStructuralTier() {
        let recorder = TraceRecorder(name: "t")
        recorder.call("Foo.bar")
        XCTAssertEqual(recorder.trace().events[0].tier, .structural)
    }
}

final class IntervalTests: XCTestCase {
    func testIntervalRecordsSubRegionSignpost() {
        let recorder = TraceRecorder(name: "t", clock: ManualClock())
        let result = TraceContext.$current.withValue(recorder) {
            Haruspec.interval("pricing") { () -> Int in
                Haruspec.simulateCost(30)
                return 42
            }
        }
        XCTAssertEqual(result, 42)
        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.kind), [.signpost])
        XCTAssertEqual(events[0].label, "pricing")
        XCTAssertEqual(events[0].durationTicks, 30)
    }

    func testIntervalRunsBodyWithoutActiveCapture() {
        XCTAssertEqual(Haruspec.interval("x") { 7 }, 7) // no recorder bound → just runs the body
    }
}

final class KVOInterceptorTests: XCTestCase {
    final class Counter: NSObject {
        @objc dynamic var count: Int = 0
    }

    func testCapturesKeyPathChangesAsStateChanges() {
        let recorder = TraceRecorder(name: "t")
        let sut = KVOInterceptor(recorder: recorder)
        let counter = Counter()
        sut.observe(counter, keyPaths: ["count"])
        counter.count = 5
        counter.count = 9
        sut.stop()

        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.kind), [.stateChange, .stateChange])
        XCTAssertEqual(events.map(\.label), ["count", "count"])
        XCTAssertEqual(events[0].payload, .int(5))
        XCTAssertEqual(events[1].payload, .int(9))
    }
}
