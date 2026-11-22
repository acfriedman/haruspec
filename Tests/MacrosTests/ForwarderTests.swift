@testable import HaruspecCore
import HaruspecMacros
import HaruspecSpec
@testable import HaruspecTrace
import XCTest

/// A stand-in for a Clang-imported Obj-C class: a plain reference type whose Swift-facing API carries
/// the implicitly-unwrapped optionals (`Product!`, `String!`, `Receipt!`) the importer would produce.
/// It carries no attribute (it's the "Obj-C" side); the forwarder brings it under capture anyway.
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
/// stamp. The peer `TracedCart` is generated: a final class conforming to `Cart` that wraps any
/// `Cart`, forwards 1:1, and emits `call`/`ret` events under the label.
@Haruspec
protocol Cart: AnyObject {
    func add(_ product: Product!, quantity: Int)
    func applyPromo(_ code: String!) -> Bool
    func checkout() -> Receipt! // IUO return — forwarded bare, no force-unwrap
    var summary: String { get } // read-only property — plain computed forward, untraced
    var note: String { get set } // settable — the setter records the write, then forwards
}

/// The baseline conforms by extension — the signatures are its own, verbatim.
extension CartManager: Cart {}

/// A port with no Haruspec attribute at all, factored differently from the baseline: `add` goes
/// through a private helper. Wrapped by the same forwarder, its trace must not know that.
final class SwiftCart: Cart {
    private var itemCount = 0
    private var lastPromo: String?
    var note = ""

    func add(_: Product!, quantity: Int) {
        bump(by: quantity)
    }

    private func bump(by quantity: Int) {
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

/// An async boundary, so an actor can conform: one requirement declared main-isolated, one not.
@Haruspec
protocol Till: AnyObject {
    func ring(amount: Int) async
    @MainActor func display(total: Int) async
}

/// The Swift 6 destination shape: an actor port, carrying nothing.
actor ActorTill: Till {
    private let center: NotificationCenter
    private var total = 0

    init(center: NotificationCenter) {
        self.center = center
    }

    func ring(amount: Int) async {
        total += amount
        center.post(name: .init("TillDidRing"), object: nil, userInfo: ["total": total])
    }

    func display(total: Int) async {
        center.post(name: .init("TillDidDisplay"), object: nil, userInfo: ["total": total])
    }
}

/// A plain-class port whose `display` honors the requirement's main isolation.
final class ClassTill: Till {
    private let center: NotificationCenter

    init(center: NotificationCenter) {
        self.center = center
    }

    func ring(amount: Int) async {
        center.post(name: .init("TillDidRing"), object: nil, userInfo: ["total": amount])
    }

    @MainActor func display(total: Int) async {
        center.post(name: .init("TillDidDisplay"), object: nil, userInfo: ["total": total])
    }
}

final class ForwarderIsolationTests: XCTestCase {
    /// A forwarded call into an actor is recorded as the actor — and the effect the actor emits
    /// from inside inherits that domain, with no attribute on the actor.
    func testAnActorConformerIsRecordedAsTheActor() async {
        let events = await capture {
            let till = TracedTill(ActorTill(center: RecordingNotificationCenter()))
            await till.ring(amount: 5)
        }

        XCTAssertEqual(events.map(\.label), ["Till.ring", "TillDidRing", "Till.ring"])
        let domains = Set(events.map(\.domain))
        XCTAssertEqual(domains.count, 1, "call, effect and return share the actor's domain: \(events.map(\.domain))")
        guard case let .actor(type, _)? = domains.first else {
            return XCTFail("expected an actor domain, got \(domains)")
        }
        XCTAssertEqual(type, "ActorTill")
    }

    /// A requirement the protocol declares `@MainActor` is recorded as `main`, and a conformer
    /// honoring it emits from `main` too — the isolation is the protocol's contract, so it needs no
    /// attribute on the port to be seen.
    func testAMainIsolatedRequirementIsRecordedAsMain() async {
        let events = await capture {
            let till = TracedTill(ClassTill(center: RecordingNotificationCenter()))
            await till.display(total: 7)
        }

        XCTAssertEqual(events.map(\.label), ["Till.display", "TillDidDisplay", "Till.display"])
        XCTAssertEqual(events.map(\.domain), [.main, .main, .main])
    }

    /// A plain class witnessing a nonisolated requirement declares nothing, so its call is ambient.
    func testANonisolatedConformerIsAmbient() async {
        let events = await capture {
            let till = TracedTill(ClassTill(center: RecordingNotificationCenter()))
            await till.ring(amount: 5)
        }

        XCTAssertEqual(events.map(\.domain), [.ambient, .ambient, .ambient])
    }

    private func capture(_ body: () async -> Void) async -> [TraceEvent] {
        let recorder = TraceRecorder(name: "t")
        await TraceContext.$current.withValue(recorder) { await body() }
        return recorder.trace().events
    }
}

final class ForwarderTests: XCTestCase {
    /// The forwarder is typed by the protocol: the baseline and a port are wrapped by the same
    /// class, and the two traces are identical — the port's private helper never appears.
    func testWrapsBaselineAndPortThroughOneBoundary() {
        func drive(_ cart: Cart) {
            cart.add(Product(sku: "A"), quantity: 3)
            _ = cart.applyPromo("SAVE")
            _ = cart.checkout()
        }
        let baseline = run { drive(TracedCart(CartManager())) }
        let port = run { drive(TracedCart(SwiftCart())) }

        XCTAssertEqual(baseline, port)
        XCTAssertFalse(port.contains { $0.label.contains("bump") }, "a port's factoring is not surface")
    }

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

    /// Each requirement records a `call`/`ret` pair under the label, arguments keyed by internal
    /// name and returns captured structurally.
    func testRecordsEachCallUnderTheLabel() {
        let forwarded = run {
            let cart = TracedCart(CartManager())
            cart.add(Product(sku: "A"), quantity: 3)
            _ = cart.applyPromo("SAVE")
            _ = cart.checkout()
        }

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

    /// A timed stamp brackets each forwarded call with a signpost interval — what a timing budget
    /// compares — and an untimed one records none.
    func testATimedStampRecordsEachCallsDuration() {
        let timed = run { TracedMeter(ManualMeter()).tick() }
        let untimed = run { _ = TracedCart(CartManager()).checkout() }

        XCTAssertEqual(timed.map(\.kind), [.call, .signpost, .ret])
        XCTAssertEqual(timed[1].label, "Meter.tick")
        XCTAssertFalse(untimed.contains { $0.kind == .signpost })
    }

    private func run(_ body: () -> Void) -> [TraceEvent] {
        let recorder = TraceRecorder(name: "t")
        TraceContext.$current.withValue(recorder, operation: body)
        return recorder.trace().events
    }
}

@Haruspec(timed: true)
protocol Meter: AnyObject {
    func tick()
}

final class ManualMeter: Meter {
    func tick() {}
}
