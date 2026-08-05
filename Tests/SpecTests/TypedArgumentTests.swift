import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// `.operations` and `.vary` used to be joined by an unchecked string, and both failure directions were
// silent. A domain declared for a key nobody reads is dropped at the `seamDomains ∩ declared`
// intersection — no gap, no warning. A mistyped *read* falls back to its `default:`, records that one
// constant into the golden, and sweeps it: EQUIVALENT over a surface that never varied. The typed form
// removes the key, so neither is expressible.

/// A cart whose behavior depends on the *pair* — a sku and the quantity it was added with.
private protocol TypedCart: AnyObject {
    func add(sku: String, quantity: Int)
    func total() -> Int
}

@Traced("TypedCart")
private final class GoodTypedCart: TypedCart {
    private let center: NotificationCenter
    private var cents = 0
    init(center: NotificationCenter) {
        self.center = center
    }

    private func price(_ sku: String) -> Int {
        ["COFFEE": 1299, "MUG": 899, "BEANS": 1699][sku] ?? 0
    }

    func add(sku: String, quantity: Int) {
        cents += price(sku) * max(0, quantity)
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["cents": cents])
    }

    func total() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": cents])
        return cents
    }
}

/// Identical except at the very top of the declared quantity domain — the shape of bug that only a
/// swept argument finds.
@Traced("TypedCart")
private final class TopOfRangeTypedCart: TypedCart {
    private let center: NotificationCenter
    private var cents = 0
    init(center: NotificationCenter) {
        self.center = center
    }

    private func price(_ sku: String) -> Int {
        ["COFFEE": 1299, "MUG": 899, "BEANS": 1699][sku] ?? 0
    }

    func add(sku: String, quantity: Int) {
        cents += price(sku) * max(0, quantity) + (quantity == 20 ? 1 : 0)
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["cents": cents])
    }

    func total() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": cents])
        return cents
    }
}

final class TypedArgumentTests: XCTestCase {
    private func makeGood(_ context: SeamContext) -> TypedCart {
        GoodTypedCart(center: context.notifications)
    }

    private func makeTopOfRangeBug(_ context: SeamContext) -> TypedCart {
        TopOfRangeTypedCart(center: context.notifications)
    }

    private func addSpec(_ name: String) -> Spec<TypedCart> {
        Spec<TypedCart>(name)
            .system(makeGood)
            .operations {
                Op("add", varying: .oneOf("COFFEE", "MUG", "BEANS"), .int(1 ... 20)) { cart, sku, quantity in
                    cart.add(sku: sku, quantity: quantity)
                }
                Op("total") { _ = $0.total() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
    }

    // MARK: - The join

    func testATypedArgumentDeclaresItsDomainWithoutAnyoneNamingItInVary() {
        let spec = addSpec("typed.join")

        XCTAssertEqual(spec.seamDomains.keys.sorted(), ["add.0", "add.1"])
        XCTAssertEqual(spec.argumentSeams, ["add.0", "add.1"])
    }

    func testANamedArgumentKeysAndPrintsUnderThatName() {
        let spec = Spec<TypedCart>("typed.named")
            .system(makeGood)
            .operations {
                Op(
                    "add",
                    varying: ArgumentDomain.oneOf("COFFEE", "MUG").named("sku"),
                    ArgumentDomain.int(1 ... 20).named("quantity")
                ) { cart, sku, quantity in
                    cart.add(sku: sku, quantity: quantity)
                }
            }

        XCTAssertEqual(spec.seamDomains.keys.sorted(), ["add.quantity", "add.sku"])
    }

    func testTheStringFormStillWorksAlongsideTheTypedOne() {
        let spec = Spec<TypedCart>("typed.mixed")
            .system(makeGood)
            .operations {
                Op("add", varying: .oneOf("COFFEE", "MUG")) { cart, sku in
                    cart.add(sku: sku, quantity: 1)
                }
                Op("bonus") { cart, seams in
                    cart.add(sku: "MUG", quantity: Int(seams.int("bonusQty", default: 1)))
                }
            }
            .vary { Seam("bonusQty", .int(1 ... 5)) }

        XCTAssertEqual(spec.seamDomains.keys.sorted(), ["add.0", "bonusQty"])
        XCTAssertEqual(spec.argumentSeams, ["add.0"], "only the typed argument is argument-declared")
    }

    // MARK: - The sweep

    func testATypedArgumentIsActuallySweptOverItsDomain() {
        let spec = addSpec("typed.sweep").vary { Ordering(max: 4, repeating: 2) }
        let recording = Cassette()
        _ = spec.capture(make: spec.makeSystem, order: spec.explorationOrder(), cassette: recording)
        let plan = spec.explorationPlan(golden: recording.snapshot())

        let quantities = Set(plan.cassettes(forOrdering: 0).flatMap { cassette in
            (cassette.tracks["add.1"] ?? []).compactMap {
                if case let .int(value) = $0 {
                    value
                } else {
                    nil
                }
            }
        })
        let skus = Set(plan.cassettes(forOrdering: 0).flatMap { cassette in
            (cassette.tracks["add.0"] ?? []).compactMap(\.canonicalString)
        })

        XCTAssertTrue(quantities.isSuperset(of: [1, 20]), "both ends of the range must be reached")
        XCTAssertEqual(skus.count, 3, "every declared SKU is a boundary value")
    }

    func testABugAtTheTopOfATypedArgumentsRangeIsCaught() {
        let spec = addSpec("typed.catch").vary { Ordering(max: 2, repeating: 2) }

        let verdict = spec.verify(against: makeTopOfRangeBug)

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
    }

    func testASweptTypedArgumentEarnsDomainCoverageWhenItHolds() {
        let spec = addSpec("typed.coverage").vary { Ordering(max: 2, repeating: 2) }

        let verdict = spec.verify(against: makeGood)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
        XCTAssertEqual(verdict.coverage.domainExercised, ["add.0", "add.1"])
    }

    func testACounterexampleNamesTheArgumentRatherThanAStringKey() {
        let spec = Spec<TypedCart>("typed.counterexample")
            .system(makeGood)
            .operations {
                Op(
                    "add",
                    varying: ArgumentDomain.oneOf("COFFEE", "MUG", "BEANS").named("sku"),
                    ArgumentDomain.int(1 ... 20).named("quantity")
                ) { cart, sku, quantity in
                    cart.add(sku: sku, quantity: quantity)
                }
                Op("total") { _ = $0.total() }.last()
            }
            .observe(notifications: ["CartChanged", "CheckoutCompleted"])
            .vary { Ordering(max: 2, repeating: 2) }

        let verdict = spec.verify(against: makeTopOfRangeBug)

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(
            verdict.report().contains("add.quantity="),
            "the counterexample should name the argument\n\(verdict.report())"
        )
    }

    // MARK: - Arity

    func testThreeArgumentsTravelAsOneGeneratedVector() {
        let spec = Spec<TypedCart>("typed.three")
            .system(makeGood)
            .operations {
                Op(
                    "add",
                    varying: ArgumentDomain.oneOf("COFFEE", "MUG").named("sku"),
                    ArgumentDomain.int(1 ... 20).named("quantity"),
                    ArgumentDomain.double(0 ... 1).named("discount")
                ) { cart, sku, quantity, discount in
                    cart.add(sku: sku, quantity: discount > 0.5 ? quantity : 0)
                }
            }

        XCTAssertEqual(spec.seamDomains.keys.sorted(), ["add.discount", "add.quantity", "add.sku"])
    }
}
