import Foundation
import HaruspecCore
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

/// Every event a capture records carries the declared op the runner was driving — including work
/// the op handed to a queue, which the seam carries across the hop the way it carries the recorder.
///
/// Events recorded after the ops (the end-state snapshots) carry none.
final class OpIdentityCaptureTests: XCTestCase {
    final class Subject {
        let queue = DispatchQueue(label: "com.emporium.ops")
        var count = 0

        func act(_ name: String) {
            Haruspec.marker("\(name)-sync")
            queue.async { Haruspec.marker("\(name)-async") }
            count += 1
        }
    }

    func testEventsCarryTheOpTheyWereRecordedUnderAcrossTheQueueHop() async {
        let spec = Spec<Subject>("ops")
            .system { _ in Subject() }
            .operations {
                Op("first") { $0.act("first") }
                Op("second") { $0.act("second") }
            }
            .observes(Observed("Subject.count") { $0.count })

        let trace = await spec.capture(make: spec.makeSystem, order: spec.operations, cassette: Cassette())
        let ops = Dictionary(uniqueKeysWithValues: trace.events.map { ($0.label, $0.op) })

        XCTAssertEqual(ops["first-sync"], OpIdentity(label: "first", position: 0))
        XCTAssertEqual(
            ops["first-async"],
            OpIdentity(label: "first", position: 0),
            "the queue hop keeps the enqueueing op"
        )
        XCTAssertEqual(ops["second-sync"], OpIdentity(label: "second", position: 1))
        XCTAssertEqual(ops["second-async"], OpIdentity(label: "second", position: 1))
        XCTAssertEqual(ops["Subject.count"], .some(nil), "an end-state snapshot is recorded under no op")
    }

    func testARepeatedOpIsTwoIdentities() async {
        let spec = Spec<Subject>("ops")
            .system { _ in Subject() }
            .operations { Op("act") { $0.act("act") } }
        let order = [spec.operations[0], spec.operations[0]]

        let trace = await spec.capture(make: spec.makeSystem, order: order, cassette: Cassette())
        let positions = trace.events.filter { $0.label == "act-sync" }.map(\.op?.position)
        XCTAssertEqual(positions, [0, 1])
    }
}
