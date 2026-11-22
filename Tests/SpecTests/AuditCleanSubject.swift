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

@Haruspec
protocol AuditedLedger: AnyObject {
    func add(cents: Int)
    func total() -> Int
}

/// Baseline: every effect goes through the injected center, which is the recorder.
final class InjectedLedger: AuditedLedger {
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
final class RestructuredLedger: AuditedLedger {
    private let center: NotificationCenter
    private var entries: [Int] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func add(cents: Int) {
        entries.append(cents)
        center.post(name: .init("LedgerChanged"), object: nil, userInfo: ["total": self.cents])
    }

    func total() -> Int {
        center.post(name: .init("LedgerRead"), object: nil, userInfo: ["total": cents])
        return cents
    }

    private var cents: Int {
        entries.reduce(0, +)
    }
}

func makeInjectedLedger(_ ctx: SeamContext) -> AuditedLedger {
    InjectedLedger(center: ctx.notifications)
}

func makeRestructuredLedger(_ ctx: SeamContext) -> AuditedLedger {
    RestructuredLedger(center: ctx.notifications)
}

// MARK: - A subject with an injected collaborator

/// A subject that hands its announcements to an injected collaborator (`Announcing`). This file
/// stays clean: the call is recorded at the collaborator's boundary, and what the collaborator does
/// past it is the fixture's business (see `AuditGateTests`, where the collaborator is deliberately
/// stamped in the bypass-carrying file).
final class AnnouncingLedger: AuditedLedger {
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
