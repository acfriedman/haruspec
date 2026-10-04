import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// One stamp per protocol, no roles. `Turnstile` is the subject and `Chime` the collaborator only
// because of how the tests below use them: the same stamp yields a forwarder, a catalog, and a
// double for each, and a spec picks which one it needs.

/// The production boundary a turnstile is injected with — unstamped, as an Obj-C protocol would be.
protocol ChimeRinging {
    func chime(times: Int)
}

@Haruspec
protocol Chime: ChimeRinging {
    func chime(times: Int)
}

@Haruspec
protocol Turnstile: AnyObject {
    init(chime: ChimeRinging, center: NotificationCenter)
    func pass(count: Int)
    var passes: Int { get }
}

final class TurnstileManager: Turnstile {
    private let chime: ChimeRinging
    private(set) var passes = 0

    init(chime: ChimeRinging, center _: NotificationCenter) {
        self.chime = chime
    }

    func pass(count: Int) {
        passes += max(0, count)
        chime.chime(times: passes)
    }
}

final class SwiftTurnstile: Turnstile {
    private let chime: ChimeRinging
    private(set) var passes = 0

    init(chime: ChimeRinging, center _: NotificationCenter) {
        self.chime = chime
    }

    func pass(count: Int) {
        passes += count > 0 ? count : 0
        chime.chime(times: passes)
    }
}

/// The collaborator migrated in its own right: `Chime` is now a subject, with nothing re-stamped.
final class BellChime: Chime {
    private(set) var rung = 0

    func chime(times: Int) {
        rung += times
    }
}

final class SwiftBellChime: Chime {
    private(set) var rung = 0

    func chime(times: Int) {
        rung += times
    }
}

/// A model with no `SeamGenerated` factory.
struct Badge {
    let id: Int
}

/// Stamped without any spec in mind: its catalog must still compile.
@Haruspec
protocol Gate: AnyObject {
    func admit(_ badge: Badge)
}

final class HaruspecStampTests: XCTestCase {
    func testTheSubjectChecksWithItsCollaboratorResolvedToTheStampedDouble() async throws {
        let verdict = try await Spec<Turnstile>(
            "turnstile.stamped",
            derivedFrom: DerivedTurnstile.self
        )
        .vary {
            Ordering(max: 3)
            Budget(runs: 30)
        }
        .baselined(on: TurnstileManager.self)
        .check(SwiftTurnstile.self)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testTheDoubleServesTheBoundaryItRefinesAndItself() {
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())

        XCTAssertTrue(context.resolve(ChimeRinging.self) is DoubleChime)
        XCTAssertTrue(context.resolve(Chime.self) is DoubleChime)
    }

    func testTheCollaboratorChecksAsASubjectWithNothingRestamped() async {
        let verdict = await Spec<Chime>("chime.stamped", derivedFrom: DerivedChime.self)
            .vary {
                Ordering(max: 3)
                Budget(runs: 30)
            }
            .baselined { _ in BellChime() }
            .verify { _ in SwiftBellChime() }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testEveryRoleRecordsUnderTheOneLabel() {
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())

        XCTAssertEqual(TracedChime(BellChime()).traceLabel, "Chime")
        XCTAssertEqual(DoubleChime(context).traceLabel, "Chime")
    }

    func testTheSubjectsDoubleReadsItsPropertiesAsGeneratedValues() {
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())

        XCTAssertEqual(DoubleTurnstile(context).passes, 0, "a property read is the seam's zero")
    }

    func testAModelArgumentWithoutAFactoryStaysPending() throws {
        let admit = try XCTUnwrap(DerivedGate.derivedOps.first)

        XCTAssertEqual(admit.label, "admit")
        XCTAssertNil(admit.arguments.first?.resolution, "pending until a spec that drives it declares values")
    }
}
