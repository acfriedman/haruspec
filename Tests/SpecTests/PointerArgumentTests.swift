import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import LegacyObjC
import XCTest

// The Cocoa enumeration shape, `BOOL *stop`, with a genuine Objective-C baseline. The stop flag
// lives in whichever frame enumerates, so its address is not behavior: a faithful Swift port hands
// its block a different address for the same flag. What the subject does with the flag — where it
// stops — is behavior, and is still compared through the deliveries it makes.

// MARK: - The boundary

/// The pasted interface: `-enumerateItemsUsingBlock:` exactly as Swift imports it.
@Haruspec
protocol Inventory: AnyObject {
    func enumerateItems(_ block: @escaping (String, UnsafeMutablePointer<ObjCBool>) -> Void)
}

extension LegacyInventory: Inventory {}

/// What every inventory enumerates.
private let items = ["alpha", "bravo", "charlie", "delta"]

// MARK: - The ports

/// A faithful port: the flag on its own stack, checked after each call.
final class SwiftInventory: Inventory {
    func enumerateItems(_ block: @escaping (String, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        for item in items {
            block(item, &stop)
            if stop.boolValue {
                break
            }
        }
    }
}

/// A faithful port that keeps the flag on the heap, so even two Swift ports disagree on its address.
final class HeapFlagInventory: Inventory {
    func enumerateItems(_ block: @escaping (String, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let stop = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
        defer { stop.deallocate() }
        stop.initialize(to: false)
        for item in items {
            block(item, stop)
            if stop.pointee.boolValue {
                break
            }
        }
    }
}

/// A port that never reads the flag, so it delivers every item whatever the caller asked.
final class StopIgnoringInventory: Inventory {
    func enumerateItems(_ block: @escaping (String, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        for item in items {
            block(item, &stop)
        }
    }
}

/// A port that notices the flag one item late, so it delivers one item too many.
final class LateStoppingInventory: Inventory {
    func enumerateItems(_ block: @escaping (String, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        var stopping = false
        for item in items {
            block(item, &stop)
            if stopping {
                break
            }
            stopping = stop.boolValue
        }
    }
}

// MARK: - A collaborator with an out-parameter

/// A collaborator that answers through an out-parameter beside its return: the
/// `-stockForSku:found:` shape, stood in for by its double.
@Haruspec
protocol Stockroom: AnyObject {
    func stock(sku: String, found: UnsafeMutablePointer<ObjCBool>) -> Int
}

/// The subject: asks the stockroom, and announces the count.
@Haruspec
protocol Restocking: AnyObject {
    func report(sku: String)
}

/// Passes the stockroom a flag on its own stack.
final class StackRestocker: Restocking {
    private let stockroom: any Stockroom
    private let center: NotificationCenter

    init(stockroom: any Stockroom, center: NotificationCenter) {
        self.stockroom = stockroom
        self.center = center
    }

    func report(sku: String) {
        var found = ObjCBool(false)
        let count = stockroom.stock(sku: sku, found: &found)
        center.post(name: .init("RestockDidReport"), object: nil, userInfo: ["sku": sku, "count": count])
    }
}

/// The same report, passing a flag on the heap.
final class HeapRestocker: Restocking {
    private let stockroom: any Stockroom
    private let center: NotificationCenter

    init(stockroom: any Stockroom, center: NotificationCenter) {
        self.stockroom = stockroom
        self.center = center
    }

    func report(sku: String) {
        let found = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
        defer { found.deallocate() }
        found.initialize(to: false)
        let count = stockroom.stock(sku: sku, found: found)
        center.post(name: .init("RestockDidReport"), object: nil, userInfo: ["sku": sku, "count": count])
    }
}

// MARK: - Tests

final class PointerArgumentTests: XCTestCase {
    func testTheDeliveryRecordsTheItemAndNoAddress() {
        let recorder = TraceRecorder(name: "enumerate")
        let inventory = TracedInventory(LegacyInventory(items: items))

        TraceContext.$current.withValue(recorder) {
            inventory.enumerateItems { item, stop in
                stop.pointee = ObjCBool(item == "bravo")
            }
        }

        let deliveries = recorder.trace().events
            .filter { $0.kind == .call && $0.label == "Inventory.enumerateItems.block" }
        XCTAssertEqual(deliveries.map(\.payload), [
            .object(["0": .string("alpha"), "1": .string("<pointer>")]),
            .object(["0": .string("bravo"), "1": .string("<pointer>")])
        ], "the flag is recorded as a pointer, and where the subject stopped as the deliveries it made")
    }

    func testTheObjCBaselineIsEquivalentToItself() async {
        let verdict = await enumeration.verify { _ in LegacyInventory(items: items) }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testAFaithfulSwiftPortIsEquivalentToTheObjCBaseline() async {
        let verdict = await enumeration.verify { _ in SwiftInventory() }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testAPortWithTheFlagOnTheHeapIsEquivalent() async {
        let verdict = await enumeration.verify { _ in HeapFlagInventory() }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testAPortThatIgnoresTheFlagDiverges() async {
        let verdict = await enumeration.verify { _ in StopIgnoringInventory() }

        XCTAssertEqual(verdict.verdict, .diverged, "where the subject stops is behavior")
        XCTAssertEqual(
            Set(verdict.diff.divergences.map(\.kind)),
            [.unexpectedEvent],
            "only the extra deliveries differ"
        )
    }

    func testAPortThatStopsOneItemLateDiverges() async {
        let verdict = await enumeration.verify { _ in LateStoppingInventory() }

        XCTAssertEqual(verdict.verdict, .diverged, "one delivery past the flag is a different contract")
        XCTAssertEqual(
            verdict.diff.divergences.map(\.kind),
            [.unexpectedEvent, .unexpectedEvent],
            "the one extra delivery's call and return, and nothing else"
        )
    }

    /// Enumerates, setting the flag at the `stopAt`th item; `0` never sets it.
    private var enumeration: BaselinedSpec<any Inventory> {
        Spec<any Inventory>("inventory.stop")
            .operations {
                Op("enumerateItems") { sut, seams in
                    let stopAt = Int(seams.int("stopAt", default: 0))
                    var seen = 0
                    sut.enumerateItems { _, stop in
                        seen += 1
                        if seen == stopAt {
                            stop.pointee = true
                        }
                    }
                }
            }
            .vary {
                Seam("stopAt", .int(0 ... 5))
                Budget(runs: 30)
            }
            .baselined { _ in LegacyInventory(items: items) }
    }

    func testADoublesOutParameterIsComparedWithoutItsAddress() async {
        let verdict = await restocking.verify { context in
            HeapRestocker(stockroom: context.double(DoubleStockroom.self), center: context.notifications)
        }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    private var restocking: BaselinedSpec<any Restocking> {
        Spec<any Restocking>("restocking.found")
            .operations {
                Op("report") { $0.report(sku: "A") }
            }
            .vary {
                Seam("Stockroom.stock", .int(0 ... 9))
                Budget(runs: 20)
            }
            .baselined { context in
                StackRestocker(stockroom: context.double(DoubleStockroom.self), center: context.notifications)
            }
    }
}
