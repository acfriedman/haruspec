import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
@testable import HaruspecTrace
import XCTest

// Where a covered label is declared — the audit's source map, stamped by the macro at expansion and
// collected when the instrumented body runs. These pin the case that makes searching for the label
// useless: `Cart` is answered by a Swift port *and* an Obj-C class behind one forwarder, neither of
// which is named "Cart". The subjects live in ForwarderTests.swift (same target): `@Haruspec protocol Cart`
// over `CartManager` and `SwiftCart`.

final class TraceOriginTests: XCTestCase {
    func testOneLabelRegistersEveryDeclarationThatAnsweredToIt() {
        let origins = collect { _ in
            TracedCart(SwiftCart()).add(Product(sku: "A"), quantity: 1)
            TracedCart(CartManager()).add(Product(sku: "A"), quantity: 1)
        }

        XCTAssertEqual(origins.map(\.label), ["Cart", "Cart"], "both declarations trace as one label")
        XCTAssertEqual(origins.map(\.symbol), ["CartManager", "SwiftCart"], "and are told apart by type")
    }

    /// A double's behavior is its generated code, so it carries the stamped protocol's `#fileID` —
    /// module-relative on purpose, since an absolute path would make the verdict machine-specific
    /// and the cross-machine freshness guard compares verdicts.
    func testADoubleCarriesTheFileThatStampsIt() throws {
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())
        let origins = collect { _ in DoubleCart(context).add(Product(sku: "A"), quantity: 1) }

        XCTAssertEqual(origins.first?.symbol, "DoubleCart")
        let source = try XCTUnwrap(origins.first?.source)
        XCTAssertTrue(source.hasSuffix("ForwarderTests.swift"), source)
        XCTAssertTrue(source.contains("/"), "a fileID is module-qualified, not a bare name")
    }

    /// A forwarder points at the wrapped class and *no* source. The behavior lives in the Obj-C
    /// implementation, not the pasted interface — naming the protocol's file would let an audit read
    /// a file with nothing in it and call the label covered.
    func testAForwardedDeclarationNamesItsWrappedTypeAndNoSource() {
        let origins = collect { _ in TracedCart(CartManager()).add(Product(sku: "A"), quantity: 1) }

        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins.first?.symbol, "CartManager")
        XCTAssertNil(origins.first?.source, "an Obj-C implementation has no Swift source to audit")
    }

    /// The symbol is read from the wrapped instance, so the same forwarder names whichever side it
    /// wraps — a Swift port's own declaration is what its audit then opens.
    func testAForwardedPortNamesThePort() {
        let origins = collect { _ in TracedCart(SwiftCart()).add(Product(sku: "A"), quantity: 1) }

        XCTAssertEqual(origins.map(\.symbol), ["SwiftCart"])
    }

    /// Registration is per *reached* method, so a class nobody called never appears — the origin set
    /// is the same population `coveredClasses` reports, not everything the build happens to contain.
    func testAnUnreachedDeclarationRegistersNothing() {
        let origins = collect { _ in TracedCart(CartManager()).add(Product(sku: "A"), quantity: 1) }

        XCTAssertEqual(origins.map(\.symbol), ["CartManager"], "SwiftCart ran in no capture here")
    }

    /// Two verifications cannot pool their sources. The collector is bound per verification rather
    /// than kept process-wide, which is what keeps specs running in parallel out of each other's
    /// verdicts — a global would hand every spec the union of everything the test process touched.
    func testCollectionIsScopedToOneVerification() {
        let manager = CartManager()
        let first = collect { _ in TracedCart(SwiftCart()).add(Product(sku: "A"), quantity: 1) }
        let second = collect { _ in TracedCart(manager).add(Product(sku: "A"), quantity: 1) }

        XCTAssertEqual(first.map(\.symbol), ["SwiftCart"])
        XCTAssertEqual(second.map(\.symbol), ["CartManager"])
    }

    /// Build the recorder *inside* the binding: it picks the collector up at init, so a capture that
    /// starts outside a verification contributes nothing rather than leaking into the last one.
    private func collect(_ body: (TraceRecorder) -> Void) -> [TraceOrigin] {
        let collector = OriginCollector()
        let recorder = TraceOrigins.$collector.withValue(collector) { TraceRecorder(name: "origins") }
        TraceContext.$current.withValue(recorder) { body(recorder) }
        return collector.snapshot
    }

    /// Instrumentation outside any collection is inert — the same shape as recording with no capture.
    func testTracingWithNothingCollectingIsHarmless() {
        let recorder = TraceRecorder(name: "unbound")

        TraceContext.$current.withValue(recorder) { TracedCart(CartManager()).add(Product(sku: "A"), quantity: 1) }

        XCTAssertEqual(recorder.trace().events.map(\.label), ["Cart.add", "Cart.add"])
    }
}
