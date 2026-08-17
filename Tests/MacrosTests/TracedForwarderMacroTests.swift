@testable import HaruspecCore
import HaruspecMacros
@testable import HaruspecTrace
import XCTest

/// A stand-in for a Clang-imported Obj-C class: a plain reference type whose Swift-facing API carries
/// the implicitly-unwrapped optionals (`Product!`, `String!`, `Receipt!`) the importer would produce.
/// `@Traced` can't annotate this (it's the "Obj-C" side); the forwarder brings it under capture anyway.
final class CartManager {
    private(set) var itemCount = 0
    private(set) var lastPromo: String?
    var note = ""

    func add(_: Product!, quantity: Int) {
        itemCount += quantity
    }

    func applyPromo(_ code: String!) -> Bool {
        lastPromo = code
        return code == "SAVE"
    }

    func checkout() -> Receipt! {
        Receipt(total: itemCount * 10)
    }

    var summary: String {
        "items:\(itemCount)"
    }
}

struct Product: Equatable { let sku: String }
struct Receipt: Equatable { let total: Int }

/// The developer pastes the class's "Generated Interface" verbatim into a protocol and attaches the
/// macro. The peer `TracedCart` is generated: a final class conforming to `Cart` that wraps a
/// `CartManager`, forwards 1:1, and emits the same `call`/`ret` events `@Traced` would.
@TracedForwarder(wrapping: CartManager.self, label: "Cart")
protocol Cart {
    func add(_ product: Product!, quantity: Int)
    func applyPromo(_ code: String!) -> Bool
    func checkout() -> Receipt! // IUO return — forwarded bare, no force-unwrap
    var summary: String { get } // read-only property — plain computed forward, untraced
    var note: String { get set } // settable — the setter records the write, then forwards
}

/// The equivalent hand-written `@Traced` "port": same stable label, forwarding to the same manager.
/// Its events are the alignment target the generated forwarder must match byte-for-byte.
@Traced("Cart")
final class CartPort {
    private let mgr: CartManager
    init(_ mgr: CartManager) {
        self.mgr = mgr
    }

    func add(_ product: Product!, quantity: Int) {
        mgr.add(product, quantity: quantity)
    }

    func applyPromo(_ code: String!) -> Bool {
        mgr.applyPromo(code)
    }

    func checkout() -> Receipt! {
        mgr.checkout()
    }
}

// A stand-in for an injected singleton collaborator: a `shared()` accessor plus a `reserve` command.
// `shared:` lets the generated forwarder self-wire to it, so the spec writes `TracedInventorySeam()`
// with no hand-wiring — the forwarder itself stays role-neutral (whether it's observed as a durable
// collaborator boundary is the spec's call, not this declaration's).
final class Ledger {
    nonisolated(unsafe) static let instance = Ledger() // test singleton; serial tests, no real sharing
    static func shared() -> Ledger {
        instance
    } // mimics `NS_SWIFT_NAME(shared())`
    private(set) var reserved: [(sku: String, qty: Int)] = []
    func reserve(sku: String, quantity: Int) {
        reserved.append((sku, quantity))
    }
}

@TracedForwarder(wrapping: Ledger.self, label: "Inventory", shared: "shared()")
protocol InventorySeam {
    func reserve(sku: String, quantity: Int)
}

final class TracedForwarderSharedInitTests: XCTestCase {
    // `shared:` makes the forwarder self-wire: the no-arg init wraps the real singleton, so no hand-wiring.
    func testSelfWiresToSharedSingleton() {
        let seam: InventorySeam = TracedInventorySeam() // wraps Ledger.shared()
        seam.reserve(sku: "SELF_WIRE", quantity: 1)
        XCTAssertTrue(Ledger.shared().reserved.contains { $0.sku == "SELF_WIRE" })
    }

    /// The self-wiring changes only the default; the forwarder still emits the standard call/ret and
    /// forwards — an explicit wrapped instance overrides the default.
    func testEmitsCallRetAndForwards() {
        let ledger = Ledger()
        let seam = TracedInventorySeam(ledger) // explicit wrapped, isolated from `shared()`
        let recorder = TraceRecorder(name: "t")

        TraceContext.$current.withValue(recorder) { seam.reserve(sku: "COFFEE", quantity: 2) }

        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.label), ["Inventory.reserve", "Inventory.reserve"]) // call + ret
        XCTAssertEqual(events.first?.payload, ["sku": "COFFEE", "quantity": 2]) // canonical args
        XCTAssertEqual(ledger.reserved.map(\.sku), ["COFFEE"]) // forwarded through
    }
}

final class TracedForwarderMacroTests: XCTestCase {
    /// The generated peer exists, is named per the default, and conforms to the protocol.
    func testGeneratesConformingPeer() {
        let cart: Cart = TracedCart(CartManager())
        XCTAssertEqual(cart.summary, "items:0")
    }

    /// Each requirement forwards 1:1 to the wrapped instance.
    func testForwardsToWrappedInstance() {
        let mgr = CartManager()
        let cart = TracedCart(mgr)

        cart.add(Product(sku: "A"), quantity: 3)
        XCTAssertEqual(mgr.itemCount, 3)
        XCTAssertTrue(cart.applyPromo("SAVE"))
        XCTAssertFalse(cart.applyPromo("NOPE"))
        XCTAssertEqual(mgr.lastPromo, "NOPE")
    }

    /// A `-> Receipt!` requirement forwards without an unwrap and captures the return value structurally.
    func testIUOReturnForwardsWithoutUnwrapAndCapturesValue() {
        let recorder = TraceRecorder(name: "t")
        let cart = TracedCart(CartManager())
        cart.add(Product(sku: "A"), quantity: 2)

        let receipt: Receipt? = TraceContext.$current.withValue(recorder) { cart.checkout() }
        XCTAssertEqual(receipt, Receipt(total: 20)) // forwarded value intact (no crash on nil, no `!`)

        let ret = recorder.trace().events.first { $0.kind == .ret && $0.label == "Cart.checkout" }
        XCTAssertEqual(ret?.payload, ["total": 20]) // return captured field-by-field
    }

    /// A read-only `var x: T { get }` requirement forwards as a computed property with no trace events.
    func testReadOnlyPropertyForwardsUntraced() {
        let recorder = TraceRecorder(name: "t")
        let cart = TracedCart(CartManager())
        cart.add(Product(sku: "A"), quantity: 5)

        let summary = TraceContext.$current.withValue(recorder) { cart.summary }
        XCTAssertEqual(summary, "items:5")
        XCTAssertTrue(recorder.trace().events.isEmpty) // property state is captured via KVO, not here
    }

    /// A `{ get set }` requirement forwards both accessors; the setter records the boundary write as
    /// a `.stateChange` (then forwards), and the getter stays untraced — reads are not effects.
    func testGetSetPropertyForwardsAndRecordsTheWrite() {
        let recorder = TraceRecorder(name: "t")
        let mgr = CartManager()
        let cart = TracedCart(mgr)

        TraceContext.$current.withValue(recorder) {
            cart.note = "gift wrap"
            _ = cart.note
        }

        XCTAssertEqual(mgr.note, "gift wrap") // forwarded through
        let events = recorder.trace().events
        XCTAssertEqual(events.map(\.kind), [.stateChange]) // one write, no read events
        XCTAssertEqual(events.first?.label, "Cart.note")
        XCTAssertEqual(events.first?.payload, .string("gift wrap"))
        XCTAssertEqual(events.first?.tier, .semantic)
    }

    /// The forwarder sees only writes that cross it — the wrapped object's internal writes are
    /// invisible — and its trace says so.
    func testForwarderDeclaresBoundaryMutationCapture() {
        XCTAssertEqual((TracedCart(CartManager()) as MutationCapturing).mutationCapture, .boundary)
    }

    /// The generated forwarder's trace aligns byte-for-byte with the hand-written `@Traced` port.
    func testTraceAlignsWithTracedPort() {
        func run(_ body: () -> Void) -> [TraceEvent] {
            let recorder = TraceRecorder(name: "t")
            TraceContext.$current.withValue(recorder, operation: body)
            return recorder.trace().events
        }

        let forwarded = run {
            let cart = TracedCart(CartManager())
            cart.add(Product(sku: "A"), quantity: 3)
            _ = cart.applyPromo("SAVE")
            _ = cart.checkout()
        }
        let ported = run {
            let port = CartPort(CartManager())
            port.add(Product(sku: "A"), quantity: 3)
            _ = port.applyPromo("SAVE")
            _ = port.checkout()
        }

        XCTAssertEqual(forwarded, ported)
        XCTAssertEqual(forwarded.map(\.label), [
            "Cart.add",
            "Cart.add",
            "Cart.applyPromo",
            "Cart.applyPromo",
            "Cart.checkout",
            "Cart.checkout"
        ])
        XCTAssertEqual(forwarded[0].payload, ["product": ["sku": "A"], "quantity": 3]) // canonical args
        XCTAssertEqual(forwarded[3].payload, .bool(true)) // Bool return captured
    }
}
