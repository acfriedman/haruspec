import Foundation
import HaruspecAudit
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// The capture-completeness gate, end to end: a real spec run, a real source tree, a real verdict.
//
// The first test is the whole card in one assertion pair — the *diff* is EQUIVALENT (both sides run
// the same code, so nothing could differ) while the *verdict* abstains. That gap is the failure mode
// the audit exists for: effects leaving through an unrecorded channel never enter either trace, so
// nothing about the comparison looks wrong.

/// A subject whose effects leave through the global center — no injected collaborator, exactly like
/// a faithful port of legacy code. Both sides of the differential are this same class: identical
/// behavior, so an EQUIVALENT diff is guaranteed and the only thing left to catch is the channel.
@Traced("BypassLedger")
final class BypassingLedger: AuditSubject {
    private var cents = 0

    func add(cents: Int) {
        self.cents += cents
        NotificationCenter.default.post(name: .init("LedgerChanged"), object: nil, userInfo: ["total": self.cents])
    }

    func total() -> Int {
        cents
    }
}

private func makeBypassingLedger(_: SeamContext) -> AuditSubject {
    BypassingLedger()
}

/// A recording collaborator double whose *declaring file is this one* — which carries a deliberate
/// `NotificationCenter.default` reach. That placement is the point of the scoping tests: an audit
/// that reads collaborator sources gates the subject on this file; one scoped by `.injects` does not.
@Traced("Announcer")
final class RecordingAnnouncer: Announcing {
    func announce(total: Int) {
        _ = total
    }
}

final class AuditGateTests: XCTestCase {
    /// The checkout the audit reads — this file is `<root>/Tests/SpecTests/AuditGateTests.swift`.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func ledger(system: @escaping (SeamContext) -> AuditSubject) -> Spec<AuditSubject> {
        Spec<AuditSubject>("audit.ledger")
            .system(system)
            .operations {
                Op("add") { ledger, seams in
                    ledger.add(cents: Int(seams.int("cents", default: 500)))
                }
                Op("total") { _ = $0.total() }.last()
            }
            .vary {
                Seam("cents", .int(1 ... 100))
            }
    }

    // MARK: - The gate

    func testAnUndeclaredBypassAbstainsNamingTheChannel() async {
        let verdict = await ledger(system: makeBypassingLedger)
            .verify(against: makeBypassingLedger)
            .audited(against: packageRoot, declaring: .none)

        XCTAssertEqual(
            verdict.diff.verdict,
            .equivalent,
            "the diff cannot see this: identical code, and the escaping effect entered neither trace"
        )
        XCTAssertEqual(verdict.verdict, .cannotVerify, "an unseen channel may not read as a pass")
        XCTAssertEqual(verdict.qualification.blindSpots, ["NotificationCenter.default"])
        XCTAssertEqual(
            verdict.coverage.blindSpots.map(\.reason),
            [.bypassedChannel],
            "the downgrade goes through coverage, so nothing new decides the verdict"
        )
    }

    func testADeclaredBlindSpotReturnsToGreenAndStaysNamed() async {
        let verdict = await ledger(system: makeBypassingLedger)
            .verify(against: makeBypassingLedger)
            .audited(
                against: packageRoot,
                declaring: Intent { Accepts(uncaptured: "NotificationCenter.default") }
            )

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertEqual(
            verdict.qualification.blindSpots,
            ["NotificationCenter.default (declared)"],
            "declaring moves a channel out of the gate, never off the verdict"
        )
        XCTAssertTrue(verdict.coverage.blindSpots.isEmpty)
    }

    func testDeclaringOneChannelSaysNothingAboutAnother() async {
        let verdict = await ledger(system: makeBypassingLedger)
            .verify(against: makeBypassingLedger)
            .audited(against: packageRoot, declaring: Intent { Accepts(uncaptured: "Timer / RunLoop") })

        XCTAssertEqual(verdict.verdict, .cannotVerify)
        XCTAssertEqual(
            verdict.qualification.blindSpots,
            ["NotificationCenter.default", "Timer / RunLoop (declared, not found)"]
        )
    }

    func testASpecLevelAcceptanceCoversEveryCandidate() async {
        // `.accepts(uncaptured:)` is the subject-fact form: the bypass lives in the baseline's own
        // sources, so no check site should have to repeat it. The merge is what the env-driven path
        // feeds the audit (`collectingOrigins`); the verdict shape it produces is pinned end to end.
        let spec = ledger(system: makeBypassingLedger).accepts(uncaptured: "NotificationCenter.default")

        XCTAssertEqual(
            spec.mergingAcceptances(into: .none).acceptedBlindSpots,
            ["NotificationCenter.default"]
        )
        XCTAssertEqual(
            spec.mergingAcceptances(into: Intent { Accepts(uncaptured: "Combine") }).acceptedBlindSpots,
            ["Combine", "NotificationCenter.default"],
            "a port's own acceptance and the subject's compose, not replace"
        )

        let verdict = await spec
            .verify(against: makeBypassingLedger)
            .audited(against: packageRoot, declaring: spec.mergingAcceptances(into: .none))

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertEqual(verdict.qualification.blindSpots, ["NotificationCenter.default (declared)"])
    }

    func testTheFirstAuditWinsSoExplicitAndEnvDrivenCompose() async {
        let once = await ledger(system: makeBypassingLedger)
            .verify(against: makeBypassingLedger)
            .audited(against: packageRoot)
        let twice = once.audited(against: packageRoot)

        XCTAssertEqual(twice.qualification.blindSpots, once.qualification.blindSpots)
        XCTAssertEqual(
            twice.coverage.blindSpots.count,
            once.coverage.blindSpots.count,
            "re-auditing an audited verdict must not stack a second copy of its gaps"
        )
    }

    // MARK: - Subject vs collaborator (the audit's denominator)

    private func announcingLedger(
        make: @escaping (SeamContext) -> AuditSubject
    ) -> Spec<AuditSubject> {
        Spec<AuditSubject>("audit.announcing-ledger")
            .system(make)
            .operations {
                Op("add") { ledger, seams in
                    ledger.add(cents: Int(seams.int("cents", default: 500)))
                }
                Op("total") { _ = $0.total() }.last()
            }
            .vary {
                Seam("cents", .int(1 ... 100))
            }
    }

    func testAnInjectedCollaboratorsSourcesAreTheFixturesNotTheSubjects() async {
        // The collaborator's declaring file carries a real bypass — but both sides call through the
        // same double, and the interaction is recorded at its boundary. Handing it through
        // `ctx.inject` IS the declaration: the double states its own label, and its sources leave
        // the denominator entirely, so the subject reads audited-clean.
        let injected = { (ctx: SeamContext) -> AuditSubject in
            AnnouncingLedger(center: ctx.notifications, announcer: ctx.inject(RecordingAnnouncer()))
        }
        let verdict = await announcingLedger(make: injected)
            .verify(against: injected)
            .audited(against: packageRoot)

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertEqual(verdict.qualification.blindSpots, [], "the fixture's file must not gate the subject")
        XCTAssertFalse(
            verdict.qualification.origins.contains { $0.label == "Announcer" },
            "an injected label leaves the denominator, not just the findings"
        )
    }

    func testACollaboratorConstructedAroundTheInjectionPointStillGates() async {
        // Not handed through `ctx.inject` = not registered: the audit over-reports — the safe
        // direction — and the exit is routing the construction through the injection point.
        let bare = { (ctx: SeamContext) -> AuditSubject in
            AnnouncingLedger(center: ctx.notifications, announcer: RecordingAnnouncer())
        }
        let verdict = await announcingLedger(make: bare)
            .verify(against: bare)
            .audited(against: packageRoot)

        XCTAssertEqual(verdict.verdict, .cannotVerify)
        XCTAssertEqual(verdict.qualification.blindSpots, ["NotificationCenter.default"])
    }

    // MARK: - The clean case, and what "clean" is allowed to mean

    func testACleanSubjectClaimsAuditedOnlyAfterReadingItsSource() async {
        let verdict = await ledger(system: makeInjectedLedger)
            .verify(against: makeRestructuredLedger)
            .audited(against: packageRoot, declaring: .none)

        XCTAssertEqual(verdict.verdict, .equivalent)
        XCTAssertEqual(verdict.qualification.blindSpots, [], "audited and clean is a claim, and it holds here")
    }

    func testAnAuditOverNoDeclarationsClaimsNothing() async {
        let verdict = await ledger(system: makeInjectedLedger)
            .verify(against: makeRestructuredLedger)
            .noting(origins: [])
            .audited(against: packageRoot, declaring: .none)

        XCTAssertNil(
            verdict.qualification.blindSpots,
            "nothing found in nothing is not a clean bill of health"
        )
    }

    func testAnUnreadableDeclarationGatesLikeABypass() async {
        let verdict = await ledger(system: makeInjectedLedger)
            .verify(against: makeRestructuredLedger)
            .noting(origins: [TraceOrigin(label: "Ledger", symbol: "LedgerThatMoved", source: nil)])
            .audited(against: packageRoot, declaring: .none)

        XCTAssertEqual(verdict.verdict, .cannotVerify)
        XCTAssertEqual(verdict.qualification.blindSpots, ["LedgerThatMoved (no source found)"])
        XCTAssertEqual(verdict.coverage.blindSpots.map(\.reason), [.unauditableSource])
    }

    // MARK: - Where the root comes from

    func testTheRootIsEnvironmentSuppliedAndItsAbsenceDisablesTheAudit() {
        XCTAssertEqual(
            AuditRoot.fromEnvironment([AuditRoot.environmentKey: "/tmp/checkout"])?.path,
            "/tmp/checkout"
        )
        XCTAssertNil(AuditRoot.fromEnvironment([:]))
        XCTAssertNil(AuditRoot.fromEnvironment([AuditRoot.environmentKey: ""]))
    }

    func testAVerifyRunWithNoConfiguredRootLeavesTheVerdictUnaudited() async {
        let verdict = await ledger(system: makeBypassingLedger).verify(against: makeBypassingLedger)

        XCTAssertNil(
            verdict.qualification.blindSpots,
            "an adopter who has not wired a root reads 'not audited', which is visibly not 'clean'"
        )
        XCTAssertEqual(verdict.verdict, .equivalent)
    }
}
