import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// One queue per domain in a capture. A domain is a label and a discipline, so two queues that share
/// both would record as one; the capture refuses, naming them.
final class DomainOwnersTests: XCTestCase {
    private final class Queue {}

    private final class Named: QueueNaming {
        func naming(_ label: String) -> String {
            "context.double(DoubleStateQueue.self, label: \"\(label)\")"
        }
    }

    private let serial = ConcurrencyDomain.queue("StateQueue", serial: true)

    func testOneQueueClaimsItsDomainAsOftenAsItLikes() {
        var owners = DomainOwners()
        let queue = Queue()

        XCTAssertNil(owners.claim(serial, for: queue))
        XCTAssertNil(owners.claim(serial, for: queue))
    }

    func testASecondQueueOnTheDomainIsRefused() throws {
        var owners = DomainOwners()

        XCTAssertNil(owners.claim(serial, for: Queue()))
        let conflict = try XCTUnwrap(owners.claim(serial, for: Queue()))

        XCTAssertTrue(conflict.contains("Two different queues record as queue(serial):StateQueue"), conflict)
        XCTAssertTrue(conflict.contains("work moved from one to the other would go unseen"), conflict)
    }

    func testTheMessageSpellsHowEachKindOfQueueIsNamed() throws {
        var owners = DomainOwners()

        _ = owners.claim(serial, for: Named())
        let conflict = try XCTUnwrap(owners.claim(serial, for: Named()))

        XCTAssertTrue(conflict.contains(#"context.double(DoubleStateQueue.self, label: "io")"#), conflict)
        XCTAssertTrue(conflict.contains(#"context.double(DoubleStateQueue.self, label: "state")"#), conflict)
    }

    func testMainIsOneQueueHoweverManySeamsReachIt() {
        var owners = DomainOwners()

        XCTAssertNil(owners.claim(.main, for: Queue()))
        XCTAssertNil(owners.claim(.main, for: Queue()))
    }

    func testALabelOrADisciplineOfItsOwnIsADomainOfItsOwn() {
        var owners = DomainOwners()

        XCTAssertNil(owners.claim(serial, for: Queue()))
        XCTAssertNil(owners.claim(.queue("IOQueue", serial: true), for: Queue()))
        XCTAssertNil(owners.claim(.queue("StateQueue", serial: false), for: Queue()))
    }
}
