import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
import HaruspecSpec
import HaruspecTrace
import XCTest

// The generated collaborator double, end to end: nobody wrote a double here. The protocol below is
// the whole authored surface — `@TracedDouble` synthesizes the class, `context.double` constructs and
// registers it, void requirements record and no-op, and the one value-returning requirement is a seam
// read: zero by default, swept when the spec declares a domain for its key, replayed like any seam.

/// The boundary the subject depends on. `TracedMetering` is generated as a peer.
@TracedDouble(label: "Meter")
protocol Metering: AnyObject {
    func record(value: Int)
    func threshold() -> Int
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
        if value > meter.threshold() {
            center.post(name: .init("OverThreshold"), object: nil, userInfo: ["value": value])
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
        if value > meter.threshold() {
            center.post(name: .init("OverThreshold"), object: nil, userInfo: ["value": value])
        }
    }
}

final class TracedDoubleTests: XCTestCase {
    private func gauge(sweepingThreshold: Bool = false) -> Spec<Gauge> {
        var spec = Spec<Gauge>("double.gauge")
            .system { ctx in MeteredGauge(center: ctx.notifications, meter: ctx.double(TracedMetering.self)) }
            .operations {
                Op("add", varying: .int(0 ... 10).named("value")) { gauge, value in
                    gauge.add(value: Int(value))
                }
            }
        if sweepingThreshold {
            spec = spec.vary {
                Seam("Meter.threshold", .int(0 ... 8))
            }
        }
        return spec
    }

    func testAGeneratedDoubleNeedsNoAuthoredImplementation() async {
        let verdict = await gauge().verify(against: { ctx in
            MeteredGauge(center: ctx.notifications, meter: ctx.double(TracedMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertTrue(
            verdict.qualification.coveredClasses.contains("Meter"),
            "the boundary is captured — record calls and threshold reads are trace events"
        )
        XCTAssertTrue(
            verdict.qualification.origins.isEmpty,
            "constructed through the context, the double is registered injected — fixture, not subject"
        )
    }

    func testASynthesizedReturnSweepsWhenTheSpecDeclaresItsDomain() async {
        let verdict = await gauge(sweepingThreshold: true).verify(against: { ctx in
            MeteredGauge(center: ctx.notifications, meter: ctx.double(TracedMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertGreaterThan(
            verdict.qualification.seamPositions["Meter.threshold"] ?? 0,
            0,
            "the double's return is declared surface: recorded, varied, and reported like any seam"
        )
    }

    func testDroppingTheBoundaryCallDiverges() async {
        let verdict = await gauge().verify(against: { ctx in
            SilentGauge(center: ctx.notifications, meter: ctx.double(TracedMetering.self))
        })

        XCTAssertEqual(verdict.verdict, .diverged, "sink traffic gates: the drop is a missing Meter.record")
    }
}
