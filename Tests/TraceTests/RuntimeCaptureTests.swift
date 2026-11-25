import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

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
        XCTAssertEqual(
            RuntimeValue.canonical(["a": 1, "b": "two"] as [String: Any]),
            ["a": 1, "b": "two"]
        )
    }

    /// A non-Encodable Swift struct is canonicalized structurally by reflection — no `Codable`
    /// conformance (and no hand-written DTO mirror) required to get a diffable payload.
    func testCanonicalizesNonEncodableStructByReflection() {
        struct Plain { let count = 1; let name = "a" }
        XCTAssertEqual(RuntimeValue.canonical(Plain()), ["count": 1, "name": "a"])
    }

    /// A plain Obj-C object (no Encodable, no Codable mirror) is walked via its runtime property
    /// list + KVC — this is the tax the reflection fallback deletes for migration authors.
    func testCanonicalizesObjCObjectByPropertyList() {
        let receipt = Receipt()
        receipt.orderID = "A-100"
        receipt.total = 42
        XCTAssertEqual(RuntimeValue.canonical(receipt), ["orderID": "A-100", "total": 42])
    }

    /// Reflection recurses: nested objects and unwrapped optionals become nested structure.
    func testCanonicalizesNestedStructureAndUnwrapsOptionals() {
        struct Line { let sku = "X"; let qty = 2 }
        struct Order { let line = Line(); let note: String? = nil; let ref: Int? = 7 }
        XCTAssertEqual(
            RuntimeValue.canonical(Order()),
            ["line": ["sku": "X", "qty": 2], "note": .null, "ref": 7]
        )
    }

    func testEnumsAndOptionSetsReadAsTheirRawValues() {
        enum Phase: Int { case idle, planning }
        enum Service: String { case ground, twoDay = "2day" }
        struct Flags: OptionSet { let rawValue: UInt }

        XCTAssertEqual(RuntimeValue.canonical(Phase.planning), .int(1))
        XCTAssertEqual(RuntimeValue.canonical(Service.twoDay), .string("2day"))
        XCTAssertEqual(RuntimeValue.canonical(Flags(rawValue: 5)), .int(5))
        XCTAssertEqual(RuntimeValue.canonical(["phase": Phase.idle] as [String: Any]), ["phase": 0])
    }

    func testThrownCocoaErrorIsStructuralWhateverItsUserInfoOrder() {
        let built = NSMutableDictionary(dictionary: ["postalCode": "09012"])
        built[NSLocalizedDescriptionKey] = "We cannot ship to that address."
        let objc = NSError(domain: "d", code: 3, userInfo: built as? [String: Any])
        let swift = NSError(
            domain: "d",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "We cannot ship to that address.", "postalCode": "09012"]
        )

        XCTAssertEqual(RuntimeValue.thrown(objc), RuntimeValue.thrown(swift))
        XCTAssertEqual(
            RuntimeValue.thrown(objc),
            [
                "domain": "d",
                "code": 3,
                "userInfo": ["postalCode": "09012", NSLocalizedDescriptionKey: "We cannot ship to that address."]
            ]
        )
    }

    func testThrownSwiftErrorKeepsItsAssociatedValues() {
        enum Refusal: Error { case short(units: Int) }

        XCTAssertNotEqual(RuntimeValue.thrown(Refusal.short(units: 1)), RuntimeValue.thrown(Refusal.short(units: 2)))
    }

    /// Two pointers to different storage canonicalize the same, whatever the pointer kind: the
    /// address is where a value lives this run, and two ports put the same flag in different frames.
    func testAPointerRecordsNoAddress() {
        let first = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 2)
        let second = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 2)
        defer {
            first.deallocate()
            second.deallocate()
        }
        let kinds: [(name: String, wrap: (UnsafeMutablePointer<ObjCBool>) -> Any)] = [
            ("UnsafeMutablePointer", { $0 }),
            ("UnsafePointer", { UnsafePointer($0) }),
            ("UnsafeMutableRawPointer", { UnsafeMutableRawPointer($0) }),
            ("UnsafeRawPointer", { UnsafeRawPointer($0) }),
            ("OpaquePointer", { OpaquePointer($0) })
        ]

        for kind in kinds {
            XCTAssertEqual(RuntimeValue.canonical(kind.wrap(first)), .string("<pointer>"), kind.name)
            XCTAssertEqual(RuntimeValue.canonical(kind.wrap(second)), .string("<pointer>"), kind.name)
        }
        XCTAssertEqual(autoreleasing(), .string("<pointer>"), "an imported NSError ** out-parameter")
    }

    /// A buffer pointer keeps its count, which is how much the subject handed over, and drops its
    /// start address like any other pointer.
    func testABufferPointerRecordsItsCountAndNoAddress() {
        let storage = UnsafeMutablePointer<Int32>.allocate(capacity: 3)
        defer { storage.deallocate() }

        XCTAssertEqual(
            RuntimeValue.canonical(UnsafeMutableBufferPointer(start: storage, count: 3)),
            .string("<buffer pointer, count 3>")
        )
        XCTAssertEqual(
            RuntimeValue.canonical(UnsafeBufferPointer(start: storage, count: 3)),
            .string("<buffer pointer, count 3>")
        )
        XCTAssertEqual(
            RuntimeValue.canonical(UnsafeMutableRawBufferPointer(start: storage, count: 12)),
            .string("<buffer pointer, count 12>"),
            "a raw buffer counts bytes"
        )
        XCTAssertEqual(
            RuntimeValue.canonical(UnsafeRawBufferPointer(start: nil, count: 0)),
            .string("<buffer pointer, count 0>")
        )
    }

    /// Recording a pointer never reads through it: an address nothing is mapped at canonicalizes
    /// like any other.
    ///
    /// - Throws: `XCTUnwrap`'s error when no pointer has the chosen bit pattern.
    func testAPointerIsNeverDereferenced() throws {
        let unmapped = try XCTUnwrap(UnsafeMutablePointer<ObjCBool>(bitPattern: 0x10))

        XCTAssertEqual(RuntimeValue.canonical(unmapped), .string("<pointer>"))
        XCTAssertEqual(
            RuntimeValue.canonical(UnsafeBufferPointer(start: unmapped, count: 4)),
            .string("<buffer pointer, count 4>")
        )
    }

    /// Whether a pointer was passed at all is still compared: a nil one is `.null`, also nested.
    func testANilPointerIsNullAndANestedPointerRecordsNoAddress() {
        struct Request {
            let stop: UnsafeMutablePointer<ObjCBool>?
            let error: UnsafeMutablePointer<ObjCBool>?
        }
        let flag = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
        defer { flag.deallocate() }

        XCTAssertEqual(RuntimeValue.canonical(UnsafeMutablePointer<ObjCBool>?.none as Any), .null)
        XCTAssertEqual(RuntimeValue.canonical(UnsafeMutablePointer<ObjCBool>?.some(flag) as Any), "<pointer>")
        XCTAssertEqual(RuntimeValue.canonical(Request(stop: flag, error: nil)), ["stop": "<pointer>", "error": .null])
        XCTAssertEqual(RuntimeValue.canonical([flag, OpaquePointer(flag)] as [Any]), ["<pointer>", "<pointer>"])
        XCTAssertEqual(RuntimeValue.canonical(["stop": flag] as [String: Any]), ["stop": "<pointer>"])
    }

    func testStillFallsBackToDescriptionForStructurelessValues() {
        let closure: () -> Void = {}
        if case .string = RuntimeValue.canonical(closure) { /* ok */ } else {
            XCTFail("expected a string fallback for a value with no keyed structure")
        }
    }
}

/// Returns how an imported `NSError **` out-parameter canonicalizes.
///
/// - Returns: What ``RuntimeValue/canonical(_:)`` records for a pointer to a local `NSError?`.
private func autoreleasing() -> CanonicalValue {
    var error: NSError?
    return canonical(of: &error)
}

/// Returns `pointer` canonicalized; a function, so `&` can pass an autoreleasing pointer.
///
/// - Parameter pointer: An out-parameter slot, as Swift imports an Obj-C `NSError **`.
/// - Returns: What ``RuntimeValue/canonical(_:)`` records for it.
private func canonical(of pointer: AutoreleasingUnsafeMutablePointer<NSError?>) -> CanonicalValue {
    RuntimeValue.canonical(pointer)
}

/// A plain Obj-C-style object with no `Encodable`/`Codable` conformance, standing in for the
/// bridged `Receipt` a migration would return.
private final class Receipt: NSObject {
    @objc var orderID: String = ""
    @objc var total: Int = 0
}

final class RecordingNotificationCenterTests: XCTestCase {
    /// Everything posted through the injected center is recorded — there is no allowlist to hide a
    /// channel the subject starts posting. Noise exclusion is the spec's `.ignore(notifications:)`,
    /// subtractive and at diff time, so the raw trace stays complete.
    func testCapturesEveryPostThroughTheInjectedCenter() {
        let recorder = TraceRecorder(name: "t")
        let center = RecordingNotificationCenter()

        TraceContext.$current.withValue(recorder) {
            center.post(name: Notification.Name("Ping"), object: nil, userInfo: ["n": 1])
            center.post(name: Notification.Name("Unlisted"), object: nil)
        }

        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.label), ["Ping", "Unlisted"])
        XCTAssertEqual(events[0].kind, .notification)
        XCTAssertEqual(events[0].payload, ["n": 1])
    }

    /// The capture window *is* the lifetime — there is no start or stop call to get wrong, because the
    /// center records only while a recorder is bound.
    func testPostsOutsideACaptureWindowAreNotRecorded() {
        let recorder = TraceRecorder(name: "t")
        let center = RecordingNotificationCenter()

        center.post(name: Notification.Name("Ping"), object: nil)

        XCTAssertTrue(recorder.trace().events.isEmpty)
    }

    func testPostsAreCapturedInOrderSynchronously() {
        let recorder = TraceRecorder(name: "t")
        let center = RecordingNotificationCenter()

        TraceContext.$current.withValue(recorder) {
            center.post(name: Notification.Name("A"), object: nil)
            center.post(name: Notification.Name("B"), object: nil)
        }

        XCTAssertEqual(recorder.trace().events.map(\.label), ["A", "B"])
    }

    /// Observers still receive what is posted: recording decorates the center, it does not replace it.
    func testPostingStillDeliversToObservers() {
        let center = RecordingNotificationCenter()
        var received = 0
        let token = center.addObserver(forName: Notification.Name("Ping"), object: nil, queue: nil) { _ in
            received += 1
        }
        defer { center.removeObserver(token) }

        center.post(name: Notification.Name("Ping"), object: nil)

        XCTAssertEqual(received, 1)
    }

    /// Isolation is structural: a window records what is posted through *its* center, so a concurrent
    /// window's posts never reach it — even across threads, and with no filtering to get wrong.
    func testSeparateCentersDoNotCrossPollinate() {
        let recorderA = TraceRecorder(name: "a")
        let recorderB = TraceRecorder(name: "b")
        let centerA = RecordingNotificationCenter()
        let centerB = RecordingNotificationCenter()

        TraceContext.$current.withValue(recorderA) {
            centerA.post(name: Notification.Name("Ping"), object: nil, userInfo: ["src": 1])
        }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            TraceContext.$current.withValue(recorderB) {
                centerB.post(name: Notification.Name("Ping"), object: nil, userInfo: ["src": 2])
            }
            done.signal()
        }
        done.wait()

        XCTAssertEqual(recorderA.trace().events.map(\.payload), [["src": 1]])
        XCTAssertEqual(recorderB.trace().events.map(\.payload), [["src": 2]])
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
