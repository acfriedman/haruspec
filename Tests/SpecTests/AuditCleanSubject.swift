import Foundation
import HaruspecMacros
import HaruspecSeams
import HaruspecSpec
import HaruspecTrace

// A subject that reaches nothing the capture cannot see, alone in its own file on purpose.
//
// The lint reads *files*, not declarations: a class resolves to the file that declares it and every
// deny-listed reach in that file lands on the verdict. That is the safe direction (over-report, one
// reviewable line to declare away), but it means "audited — no blind spots" can only be demonstrated
// by a subject whose file is clean throughout. `SpecPrototypeTests.swift` is not — `DefaultPinger`
// posts through `NotificationCenter.default` there, deliberately — so the clean case lives here.

protocol AuditSubject: AnyObject {
    func add(cents: Int)
    func total() -> Int
}

/// Baseline: every effect goes through the injected center, which is the recorder.
@Traced("Ledger")
final class InjectedLedger: AuditSubject {
    private let center: NotificationCenter
    private var cents = 0

    init(center: NotificationCenter) {
        self.center = center
    }

    func add(cents: Int) {
        self.cents += cents
        center.post(name: .init("LedgerChanged"), object: nil, userInfo: ["total": self.cents])
    }

    func total() -> Int {
        center.post(name: .init("LedgerRead"), object: nil, userInfo: ["total": cents])
        return cents
    }
}

/// A behavior-preserving refactor of the baseline — same effects, different storage.
@Traced("Ledger")
final class RestructuredLedger: AuditSubject {
    private let center: NotificationCenter
    private var entries: [Int] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    private var cents: Int {
        entries.reduce(0, +)
    }

    func add(cents: Int) {
        entries.append(cents)
        center.post(name: .init("LedgerChanged"), object: nil, userInfo: ["total": self.cents])
    }

    func total() -> Int {
        center.post(name: .init("LedgerRead"), object: nil, userInfo: ["total": cents])
        return cents
    }
}

func makeInjectedLedger(_ ctx: SeamContext) -> AuditSubject {
    InjectedLedger(center: ctx.notifications)
}

func makeRestructuredLedger(_ ctx: SeamContext) -> AuditSubject {
    RestructuredLedger(center: ctx.notifications)
}

// MARK: - A subject with an injected collaborator

/// What the ledger announces through — a collaborator boundary. The audit's question is where the
/// *implementation* of this protocol lives, and whether its file is the subject's problem.
protocol Announcing: AnyObject {
    func announce(total: Int)
}

/// A subject that hands its announcements to an injected collaborator. This file stays clean: the
/// call is recorded at the collaborator's boundary, and what the collaborator does past it is the
/// fixture's business (see `AuditGateTests`, where the implementation deliberately lives in the
/// bypass-carrying file).
@Traced("Ledger")
final class AnnouncingLedger: AuditSubject {
    private let center: NotificationCenter
    private let announcer: Announcing
    private var cents = 0

    init(center: NotificationCenter, announcer: Announcing) {
        self.center = center
        self.announcer = announcer
    }

    func add(cents: Int) {
        self.cents += cents
        center.post(name: .init("LedgerChanged"), object: nil, userInfo: ["total": self.cents])
        announcer.announce(total: self.cents)
    }

    func total() -> Int {
        cents
    }
}
