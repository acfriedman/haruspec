import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
import HaruspecSpec
import HaruspecTrace
import XCTest

// The generated collaborator double, end to end: nobody wrote a double here. The protocol below is
// the whole authored surface — `@Haruspec` synthesizes the class, `context.double` constructs and
// registers it, void requirements record and no-op, and the one value-returning requirement is a seam
// read: zero by default, swept when the spec declares a domain for its key, replayed like any seam.

/// The boundary the subject depends on. `DoubleMetering` is generated as a peer.
@Haruspec
protocol Metering: AnyObject {
    func record(value: Int)
    func threshold() -> Int
    func tariff() -> Fee
    func lastFee() -> Fee?
    func history() -> [Int]
}

/// A custom return type — no universal zero, so the spec declares its factory (`.generates`).
struct Fee: Equatable {
    let cents: Int
}

/// The reusable form: the model carries its own mutation spec. Any spec adopts it with
/// `.generates(Fee.self)` and the field domains travel along — no `.vary` required.
extension Fee: SeamGenerated {
    static func generated(from fields: FieldSeams) -> Fee {
        Fee(cents: Int(fields.int("cents", in: 1 ... 9)))
    }
}

protocol Gauge: AnyObject {
    func add(value: Int)
}

/// A subject that both *tells* the collaborator things and *reads* it: `record` is sink traffic the
/// diff checks at the boundary, `threshold` is collaborator output steering subject behavior — the
/// generated-input case.
private final class MeteredGauge: Gauge {
    private let center: NotificationCenter
    private let meter: Metering

    init(center: NotificationCenter, meter: Metering) {
        self.center = center
        self.meter = meter
    }

    func add(value: Int) {
        meter.record(value: value)
        // The custom returns steer behavior: the fee's cents ride the payload, the optional's absence
        // takes a branch, the collection's emptiness another — all synthesized. Read unconditionally:
        // a domain declared on a read the golden template never reaches is an unmatchedDomain gate.
        let surcharge = value + meter.tariff().cents
        let repeated = meter.lastFee() != nil || !meter.history().isEmpty
        if value > meter.threshold() {
            center.post(
                name: .init("OverThreshold"),
                object: nil,
                userInfo: ["value": surcharge, "repeated": repeated]
            )
        }
    }
}

/// A "port" that stops telling the collaborator — the boundary drop the recorded double must catch.
private final class SilentGauge: Gauge {
    private let center: NotificationCenter
    private let meter: Metering

    init(center: NotificationCenter, meter: Metering) {
        self.center = center
        self.meter = meter
    }

    func add(value: Int) {
        let surcharge = value + meter.tariff().cents
        let repeated = meter.lastFee() != nil || !meter.history().isEmpty
        if value > meter.threshold() {
            center.post(
                name: .init("OverThreshold"),
                object: nil,
                userInfo: ["value": surcharge, "repeated": repeated]
            )
        }
    }
}

final class DoubleTests: XCTestCase {
    private func gauge(sweepingThreshold: Bool = false) -> Spec<Gauge> {
        var spec = Spec<Gauge>("double.gauge")
            .system { ctx in MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self)) }
            .operations {
                Op("add", varying: .int(0 ... 10).named("value")) { gauge, value in
                    gauge.add(value: Int(value))
                }
            }
            // The custom return's factory: every field a seam read under the synthesized key, so the
            // fee is recorded, sweepable at "Metering.tariff.cents", and identical on both sides.
            .generates(Fee.self) { seams, key in
                Fee(cents: Int(seams.int("\(key).cents", default: 3)))
            }
        if sweepingThreshold {
            spec = spec.vary {
                Seam("Metering.threshold", .int(0 ... 8))
            }
        }
        return spec
    }

    func testAGeneratedDoubleNeedsNoAuthoredImplementation() async {
        let verdict = await gauge().verify(against: { ctx in
            MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertTrue(
            verdict.qualification.coveredClasses.contains("Metering"),
            "the boundary is captured — record calls and threshold reads are trace events"
        )
        XCTAssertTrue(
            verdict.qualification.origins.isEmpty,
            "constructed through the context, the double is registered injected — fixture, not subject"
        )
    }

    func testASynthesizedReturnSweepsWhenTheSpecDeclaresItsDomain() async {
        let verdict = await gauge(sweepingThreshold: true).verify(against: { ctx in
            MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertGreaterThan(
            verdict.qualification.seamPositions["Metering.threshold"] ?? 0,
            0,
            "the double's return is declared surface: recorded, varied, and reported like any seam"
        )
    }

    func testACustomReturnComesFromTheDeclaredFactory() async {
        // tariff() -> Fee has no zero: the .generates factory builds it from seam reads, so the
        // surcharge lands in the payload deterministically. lastFee() -> Fee? defaults nil and
        // history() -> [Int] defaults empty with no declaration at all — "repeated" stays false.
        let verdict = await gauge().verify(against: { ctx in
            MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .equivalent)
    }

    func testAFactoryFieldSweepsLikeAnyOtherSeam() async {
        let verdict = await gauge()
            .vary {
                Seam("Metering.tariff.cents", .int(1 ... 9))
            }
            .verify(against: { ctx in
                MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self))
            })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertGreaterThan(
            verdict.qualification.seamPositions["Metering.tariff.cents"] ?? 0,
            0,
            "a custom return's field is declared surface — swept and reported like an op argument"
        )
    }

    /// The reusable generator: `.generates(Fee.self)` adopts the model's own `SeamGenerated`
    /// definition, and its field domains travel with it — swept and reported with no `.vary` at all.
    func testAModelsOwnGeneratorTravelsWithItsDomains() async {
        let spec = Spec<Gauge>("double.gauge.conformance")
            .system { ctx in MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self)) }
            .operations {
                Op("add", varying: .int(0 ... 10).named("value")) { gauge, value in
                    gauge.add(value: Int(value))
                }
            }
            .generates(Fee.self)

        let verdict = await spec.verify(against: { ctx in
            MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertGreaterThan(
            verdict.qualification.seamPositions["Fee.cents"] ?? 0,
            0,
            "adopting the model's generator declares its mutation surface — nothing restated in .vary"
        )
    }

    /// The model states how a field *can* mutate; a spec may narrow how it *does* — an explicit
    /// `Seam` on the type-scoped key wins over the generator's domain in either declaration order.
    func testASpecNarrowsAModelFieldWithAnExplicitSeam() async {
        let verdict = await Spec<Gauge>("double.gauge.narrowed")
            .system { ctx in MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self)) }
            .operations {
                Op("add", varying: .int(0 ... 10).named("value")) { gauge, value in
                    gauge.add(value: Int(value))
                }
            }
            .vary {
                Seam("Fee.cents", .int(7 ... 7))
            }
            .generates(Fee.self)
            .verify(against: { ctx in
                MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self))
            })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertGreaterThan(verdict.qualification.seamPositions["Fee.cents"] ?? 0, 0)
    }

    /// The structured op input: `.generated(Fee.self)` hands the op a whole model built by its own
    /// factory — fields discovered at declaration time, swept under type-scoped keys, the maker
    /// registered by the argument itself (no `.generates` call anywhere).
    func testAGeneratedModelAsAnOpArgument() async {
        let spec = Spec<Gauge>("double.gauge.argument")
            .system { ctx in MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self)) }
            .operations {
                Op("charge", varying: .generated(Fee.self), .int(0 ... 10).named("bump")) { gauge, fee, bump in
                    gauge.add(value: fee.cents + Int(bump))
                }
            }

        let verdict = await spec.verify(against: { ctx in
            MeteredGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertGreaterThan(
            verdict.qualification.seamPositions["Fee.cents"] ?? 0,
            0,
            "the argument's model fields are declared surface, same as a .generates adoption"
        )
        XCTAssertGreaterThan(
            verdict.qualification.seamPositions["charge.bump"] ?? 0,
            0,
            "a scalar argument beside a generated one keeps its own op-scoped track"
        )
    }

    func testDroppingTheBoundaryCallDiverges() async {
        let verdict = await gauge().verify(against: { ctx in
            SilentGauge(center: ctx.notifications, meter: ctx.double(DoubleMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .diverged, "sink traffic gates: the drop is a missing Metering.record")
    }
}
