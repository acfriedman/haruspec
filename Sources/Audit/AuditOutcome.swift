import Foundation

// What an audit *means for a verdict*, once the author's accepted blind spots are applied. The split
// lives here rather than in the Spec layer because it is the audit's own vocabulary — but it takes
// the acceptances as plain channel names, so this module stays free of `Intent` (and of Core).
//
// Four outcomes, because "declared" is not one fact:
//   bypassed   — found, undeclared → gates
//   unreadable — could not be read at all → gates
//   accepted   — found and declared → named on the verdict, does not gate
//   unmatched  — declared, found nowhere → named, does not gate, and is the one to watch
//
// The fourth is the notification-allowlist lesson written into the model: an entry that matches
// nothing looks exactly like one that matches, so a declaration nothing satisfies must be visible
// rather than quietly effective. Deleting it is how a subject that *stopped* reaching a channel gets
// its clean bill of health back.

/// One audit's findings, resolved against what the author declared.
public struct AuditOutcome: Sendable, Equatable {
    /// Channels reached around the recorder and not declared. These gate.
    public let bypassed: [String]
    /// Declarations whose source could not be read. These gate.
    public let unreadable: [String]
    /// Declared channels the audit did find — named on the verdict, not gating.
    public let accepted: [String]
    /// Declared channels the audit did not find anywhere.
    public let unmatched: [String]

    public init(bypassed: [String], unreadable: [String], accepted: [String], unmatched: [String]) {
        self.bypassed = bypassed
        self.unreadable = unreadable
        self.accepted = accepted
        self.unmatched = unmatched
    }

    /// Whether anything here must stop an otherwise-equivalent verdict.
    public var gates: Bool {
        !bypassed.isEmpty || !unreadable.isEmpty
    }

    /// Every blind spot as the qualification block prints it, gating first. An empty array is the
    /// *claim* "audited, nothing found" — only an audit that actually ran may produce it.
    public var entries: [String] {
        bypassed
            + unreadable.map { "\($0) (no source found)" }
            + accepted.map { "\($0) (declared)" }
            + unmatched.map { "\($0) (declared, not found)" }
    }
}

public extension AuditReport {
    /// Folds the report into what a verdict has to read: gating findings, declared ones, and
    /// declarations that matched nothing.
    ///
    /// `injectableDefaults` are deliberately absent — a default supplied at an injection point is a
    /// fact about the source that only becomes an escape if the spec failed to inject there, which is
    /// a fact about the *run*. The runtime tripwire owns that; gating on it here would make every
    /// legacy initializer abstain.
    func outcome(accepting accepted: [String]) -> AuditOutcome {
        let found = orderedUnique(bypasses.map(\.channel))
        let declared = orderedUnique(accepted)
        return AuditOutcome(
            bypassed: found.filter { !declared.contains($0) },
            unreadable: unresolved.compactMap(\.unresolvedSymbol),
            accepted: declared.filter { found.contains($0) },
            unmatched: declared.filter { !found.contains($0) }
        )
    }
}
