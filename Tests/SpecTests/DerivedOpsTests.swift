import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// The `.operations` block, derived. The macro writes the mechanical two-thirds — bindings and
// type-heuristic domains — and the authored residue arrives as `Amend` amendments: a String's
// values, a `.last()`. The collapse must not manufacture a silent green, so the engine-supplied
// domains are marked on the verdict and a pending argument traps naming its fix.

/// The boundary protocol a spec would interrogate. `sku` is pending (String), `quantity` defaults,
/// `eager` defaults to both values, `total` derives with no arguments.
@DerivedOps
protocol MeteredCart: AnyObject {
    func add(sku: String, quantity: Int)
    func setEager(_ eager: Bool)
    func total() -> Int
}

@Traced("MeteredCart")
final class GoodMeteredCart: MeteredCart {
    private let center: NotificationCenter
    private var cents = 0
    private var eager = false
    init(center: NotificationCenter) {
        self.center = center
    }

    private func price(_ sku: String) -> Int {
        ["COFFEE": 1299, "MUG": 899][sku] ?? 0
    }

    func add(sku: String, quantity: Int) {
        cents += price(sku) * max(0, quantity)
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["cents": cents])
    }

    func setEager(_ eager: Bool) {
        self.eager = eager
    }

    func total() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": cents])
        return cents
    }
}

/// Identical except at one decade rollover inside the *derived* quantity ladder — only reachable
/// if the engine-supplied default is actually swept to its scheduled edges.
@Traced("MeteredCart")
final class TopOfDerivedDomainCart: MeteredCart {
    private let center: NotificationCenter
    private var cents = 0
    init(center: NotificationCenter) {
        self.center = center
    }

    func add(sku: String, quantity: Int) {
        cents += (["COFFEE": 1299, "MUG": 899][sku] ?? 0) * max(0, quantity) + (quantity == 100 ? 1 : 0)
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["cents": cents])
    }

    func setEager(_ eager: Bool) {
        _ = eager
    }

    func total() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": cents])
        return cents
    }
}

/// Treats a negative quantity as a purchase where the baseline rejects it — the divergence only a
/// negative probe reaches, which is why the derived ladder carries both signs.
@Traced("MeteredCart")
final class NegativeBlindCart: MeteredCart {
    private let center: NotificationCenter
    private var cents = 0
    init(center: NotificationCenter) {
        self.center = center
    }

    func add(sku: String, quantity: Int) {
        cents += (["COFFEE": 1299, "MUG": 899][sku] ?? 0) * quantity
        center.post(name: .init("CartChanged"), object: nil, userInfo: ["cents": cents])
    }

    func setEager(_ eager: Bool) {
        _ = eager
    }

    func total() -> Int {
        center.post(name: .init("CheckoutCompleted"), object: nil, userInfo: ["total": cents])
        return cents
    }
}

/// The structured/unsupported end of the heuristic: a `SeamGenerated` model derives through its own
/// factory, a `Double` defaults, and a collection parameter is pending — no heuristic to guess with.
@DerivedOps
protocol WidgetDock: AnyObject {
    func attach(_ widget: Widget, tilt: Double)
    func flush(_ tags: [String])
}

/// Narrow widths: the emitted conversions trap on overflow, so each family's span must fit its type.
@DerivedOps
protocol NarrowKnobs: AnyObject {
    func warm(level: Int8)
    func tick(_ count: UInt8)
    func spin(rate: UInt)
}

final class Widget {
    var size = 0
}

extension Widget: SeamGenerated {
    static func generated(from fields: FieldSeams) -> Widget {
        let widget = Widget()
        widget.size = Int(fields.int("size", in: 1 ... 5))
        return widget
    }
}

final class DerivedOpsTests: XCTestCase {
    private func makeGood(_ context: SeamContext) -> MeteredCart {
        GoodMeteredCart(center: context.notifications)
    }

    private func makeTopOfDomainBug(_ context: SeamContext) -> MeteredCart {
        TopOfDerivedDomainCart(center: context.notifications)
    }

    private func makeNegativeBlind(_ context: SeamContext) -> MeteredCart {
        NegativeBlindCart(center: context.notifications)
    }

    /// The collapsed spec: the derivation plus its authored residue — the sku values and the `.last()`.
    private func cartSpec(_ name: String) -> Spec<MeteredCart> {
        Spec<MeteredCart>(name)
            .system(makeGood)
            .operations(derivedFrom: DerivedMeteredCart.self) {
                Amend("add").varying("sku", over: .oneOf("COFFEE", "MUG"))
                Amend("total").last()
            }
    }

    // MARK: - Derivation

    func testTheMacroDerivesOneOpPerMethodRequirement() {
        XCTAssertEqual(DerivedMeteredCart.derivedOps.map(\.label), ["add", "setEager", "total"])
    }

    func testAStringArgumentIsPendingRatherThanDefaulted() {
        let add = DerivedMeteredCart.derivedOps[0]
        XCTAssertEqual(add.arguments.map(\.name), ["sku", "quantity"])
        XCTAssertNil(add.arguments[0].resolution, "a String has no honest default")
        XCTAssertNotNil(add.arguments[1].resolution, "an Int defaults to the engine domain")
        XCTAssertTrue(add.arguments[1].isDerivedDefault)
    }

    func testACollectionArgumentIsPendingAndAModelDerivesThroughItsFactory() {
        let ops = DerivedWidgetDock.derivedOps
        XCTAssertEqual(ops.map(\.label), ["attach", "flush"])
        XCTAssertNil(ops[1].arguments[0].resolution, "no heuristic covers [String]")
        XCTAssertEqual(ops[1].arguments[0].typeName, "[String]")

        // The model's factory is the declaration, so its fields join the surface un-marked.
        let spec = Spec<WidgetDock>("dock")
            .operations(derivedFrom: DerivedWidgetDock.self) {
                Op("flush") { dock in dock.flush([]) }
            }
        XCTAssertEqual(spec.seamDomains.keys.sorted(), ["Widget.size", "attach.tilt"])
        XCTAssertEqual(spec.derivedDefaultSeams, ["attach.tilt"])
    }

    // MARK: - The merge

    func testDerivedDefaultsJoinTheSurfaceAndAreMarked() {
        let spec = cartSpec("derived.surface")

        XCTAssertEqual(
            spec.seamDomains.keys.sorted(),
            ["add.quantity", "add.sku", "setEager.eager"],
            "every argument joins the declared surface, defaulted or declared"
        )
        XCTAssertEqual(spec.argumentSeams, ["add.quantity", "add.sku", "setEager.eager"])
        XCTAssertEqual(
            spec.derivedDefaultSeams,
            ["add.quantity", "setEager.eager"],
            "the amended sku is authored; only the engine-supplied domains are marked"
        )
        guard case let .intMagnitudes(span) = spec.seamDomains["add.quantity"] else {
            return XCTFail("a wide Int defaults to the magnitude ladder")
        }
        XCTAssertEqual(span, -10000 ... 10000)
    }

    func testNarrowWidthsGetSpansTheirTypeCanRepresent() {
        let spec = Spec<NarrowKnobs>("knobs").operations(derivedFrom: DerivedNarrowKnobs.self)

        guard case let .intMagnitudes(level) = spec.seamDomains["warm.level"],
              case let .intMagnitudes(count) = spec.seamDomains["tick.count"],
              case let .intMagnitudes(rate) = spec.seamDomains["spin.rate"]
        else {
            return XCTFail("every integer width ladders")
        }
        XCTAssertEqual(level, -100 ... 100, "Int8's conversion traps past ±127")
        XCTAssertEqual(count, 0 ... 100, "UInt8: unsigned and width-clipped")
        XCTAssertEqual(rate, 0 ... 10000, "UInt: the wide span, no negative side")
    }

    func testDerivedOpsRepeatOverARangeFromZeroAndLastImpliesOnce() {
        let spec = cartSpec("derived.repetition")

        XCTAssertEqual(spec.operations[0].multiplicity, 0 ... 3, "absence is part of the default surface")
        XCTAssertEqual(spec.operations[2].multiplicity, 1 ... 1)
        XCTAssertTrue(spec.operations[2].mustBeLast)
    }

    func testAmendmentsCarryStructureWithoutReauthoringTheBinding() {
        let spec = Spec<MeteredCart>("derived.structure")
            .system(makeGood)
            .operations(derivedFrom: DerivedMeteredCart.self) {
                Amend("add").varying("sku", over: .oneOf("COFFEE")).repeating(0 ... 6).after("setEager")
                Amend("total").last()
            }

        XCTAssertEqual(spec.operations[0].multiplicity, 0 ... 6)
        XCTAssertEqual(spec.operations[0].afters, ["setEager"])
    }

    func testADomainValueIsReusableAcrossAmendments() {
        // Domains are plain values, so a shared vocabulary is a `let`, not a new abstraction.
        let skus: ArgumentDomain<String> = .oneOf("COFFEE", "MUG")
        let spec = Spec<MeteredCart>("derived.reused")
            .system(makeGood)
            .operations(derivedFrom: DerivedMeteredCart.self) {
                Amend("add").varying("sku", over: skus)
                Amend("total").last()
            }

        XCTAssertEqual(
            spec.seamDomains.keys.sorted(),
            ["add.quantity", "add.sku", "setEager.eager"],
            "the domain is keyed by the *parameter's* name, stated once at the call"
        )
    }

    func testAnAuthoredOpReplacesItsDerivedTwinInPlace() {
        let spec = Spec<MeteredCart>("derived.replace")
            .system(makeGood)
            .operations(derivedFrom: DerivedMeteredCart.self) {
                Op(
                    "add",
                    varying: .oneOf("COFFEE").named("sku"),
                    .int(1 ... 5).named("quantity")
                ) { cart, sku, quantity in
                    cart.add(sku: sku, quantity: quantity)
                }
                Amend("total").last()
            }

        XCTAssertEqual(spec.operations.map(\.label), ["add", "setEager", "total"], "position is kept")
        XCTAssertEqual(
            spec.derivedDefaultSeams,
            ["setEager.eager"],
            "a replaced op's arguments are authored, not derived"
        )
        XCTAssertNil(spec.operations[0].multiplicity, "an authored op keeps its own defaults")
    }

    // MARK: - The sweep (the derivation is real surface, not bookkeeping)

    func testACollapsedSpecHoldsEquivalenceOverItsDerivedSurface() async {
        let spec = cartSpec("derived.equivalent").vary {
            Ordering(max: 4)
            Budget(runs: 160)
        }

        let verdict = await spec.verify(against: makeGood)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testABugAtTheTopOfTheDerivedDefaultDomainIsCaught() async {
        let spec = cartSpec("derived.edge").vary {
            Ordering(max: 4)
            Budget(runs: 160)
        }

        let verdict = await spec.verify(against: makeTopOfDomainBug)

        XCTAssertEqual(
            verdict.verdict,
            .diverged,
            "the engine default must be swept to its edges, or it is a silent cap\n\(verdict.report())"
        )
    }

    func testANegativeProbeIsPartOfTheDerivedDefaultSurface() async {
        let spec = cartSpec("derived.negative").vary {
            Ordering(max: 4)
            Budget(runs: 160)
        }

        let verdict = await spec.verify(against: makeNegativeBlind)

        XCTAssertEqual(
            verdict.verdict,
            .diverged,
            "a candidate that mishandles a negative the baseline rejects must be caught\n\(verdict.report())"
        )
    }

    // MARK: - Honesty

    func testTheVerdictMarksWhichDomainsWereDerivedDefaults() async {
        let spec = cartSpec("derived.marked").vary {
            Ordering(max: 2)
            Budget(runs: 60)
        }

        let verdict = await spec.verify(against: makeGood)

        XCTAssertEqual(verdict.qualification.derivedDefaults, ["add.quantity", "setEager.eager"])
        XCTAssertTrue(
            verdict.report().contains("derived default"),
            "a green over a defaulted surface has to say so\n\(verdict.report())"
        )
        XCTAssertFalse(
            verdict.report().contains("add.sku (") && verdict.report()
                .contains("add.sku (declared, never read · derived default"),
            "the authored sku domain is not marked"
        )
    }

    func testAVerdictSerializedWithoutTheMarkerStillDecodes() throws {
        // The field is additive: a stored verdict from before it existed decodes to nil, which
        // renders as no marker rather than failing the read.
        let decoded = try JSONDecoder().decode(
            Qualification.self,
            from: Data("""
            {"coveredClasses":["MeteredCart"],"operations":3,"probes":9,"seamPositions":{},"origins":[]}
            """.utf8)
        )
        XCTAssertNil(decoded.derivedDefaults)
    }
}
