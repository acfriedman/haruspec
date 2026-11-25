import Foundation

// An `Intent` exploded into its atoms: one matcher per declaration, each paired with the DSL
// spelling every rendering of it uses. Classification folds over this list; the unobserved-intent
// check is its complement.

/// One atomic declaration inside an `Intent` — the unit "declared but not observed" is measured in.
///
/// `text` is the declaration's DSL spelling (`Changes("Search.query").increases()`), so a warning
/// about a dead declaration names exactly the line to delete.
struct IntentDeclaration: Sendable {
    let text: String
    /// Whether the declaration is *about* this divergence — its kind, label, field, and the op it
    /// is scoped to — before the modifiers that say what to expect there have their say.
    ///
    /// A head that matches while `matches` does not is a rejection: the author's own tripwire.
    let headMatches: @Sendable (Divergence) -> Bool
    let matches: @Sendable (Divergence, ProbeEvidence) -> Bool
}

extension Intent {
    /// The intent exploded into its atomic declarations, each pairing a matcher with its DSL spelling.
    ///
    /// ``declares(_:evidence:)`` is a fold over this list, and the unobserved-intent check is its
    /// complement: a declaration no divergence matched describes a change nobody saw.
    ///
    /// `acceptedBlindSpots` is deliberately absent: it excuses a *channel* the diff could never
    /// observe, and the capture-completeness audit already reports an acceptance that matched
    /// nothing (`AuditOutcome`).
    ///
    /// Order is deterministic (kind-grouped, value changes label-sorted) so the warning renders
    /// stably across runs.
    var declarations: [IntentDeclaration] {
        var atoms: [IntentDeclaration] = []
        // An emitted event exists on the candidate side, an omitted one on the baseline side — a
        // position modifier is checked where the event is.
        for event in expectedNewEvents {
            let text = "Emits(\(quoted(event.label)))\(event.modifiersText)"
            let head: @Sendable (Divergence) -> Bool = {
                $0.kind == .unexpectedEvent && $0.label == event.label && event.scope.isAbout($0)
            }
            atoms.append(IntentDeclaration(text: text, headMatches: head) { divergence, evidence in
                head(divergence)
                    && event.modifiersHold(
                        for: divergence,
                        at: divergence.candidateSeq,
                        in: evidence.candidate,
                        evidence: evidence
                    )
            })
        }
        for event in expectedRemovedEvents {
            let text = "Omits(\(quoted(event.label)))\(event.modifiersText)"
            let head: @Sendable (Divergence) -> Bool = {
                $0.kind == .missingEvent && $0.label == event.label && event.scope.isAbout($0)
            }
            atoms.append(IntentDeclaration(text: text, headMatches: head) { divergence, evidence in
                head(divergence)
                    && event.modifiersHold(
                        for: divergence,
                        at: divergence.baselineSeq,
                        in: evidence.baseline,
                        evidence: evidence
                    )
            })
        }
        // Per-field atoms: declaring one field never excuses — and is never excused by — another.
        let valueChanges = expectedValueChanges.sorted {
            ($0.label, $0.field ?? "") < ($1.label, $1.field ?? "")
        }
        for change in valueChanges {
            let head: @Sendable (Divergence) -> Bool = { divergence in
                divergence.kind == .valueMismatch
                    && divergence.label == change.label
                    && change.field.map { Self.fieldMatches($0, divergence.field) } ?? true
                    && change.scope.isAbout(divergence)
            }
            atoms.append(IntentDeclaration(text: change.dslText, headMatches: head) { divergence, evidence in
                head(divergence)
                    && change.relation.map {
                        $0.holds(baseline: divergence.baselineValue, candidate: divergence.candidateValue)
                    } ?? true
                    && change.conditions.allHold(in: evidence.inputs)
                    && change.scope.map { $0.holds(for: divergence, among: evidence.siblings(of: divergence)) } ?? true
            })
        }
        for domain in expectedOrderingRelaxations {
            let head: @Sendable (Divergence) -> Bool = {
                $0.kind == .orderingRelaxed && domain.matches($0.fromDomain)
            }
            let text = "Relaxes(orderingOf: \(domain.dslText))"
            atoms.append(IntentDeclaration(text: text, headMatches: head) { divergence, _ in head(divergence) })
        }
        for label in expectedOrderingLosses {
            let head: @Sendable (Divergence) -> Bool = { $0.kind == .orderingLost && $0.label == label }
            let text = "Drops(synchronizationOf: \(quoted(label)))"
            atoms.append(IntentDeclaration(text: text, headMatches: head) { divergence, _ in head(divergence) })
        }
        for label in expectedOrderingAdditions {
            let head: @Sendable (Divergence) -> Bool = { $0.kind == .orderingAdded && $0.label == label }
            atoms.append(IntentDeclaration(text: "Awaits(\(quoted(label)))", headMatches: head) { divergence, _ in
                head(divergence)
            })
        }
        // A directed reorder is proved from both sides: the event sits on the declared side of the
        // anchor in the candidate and sat on the other side of it in the baseline.
        for reorder in expectedReorders {
            let head: @Sendable (Divergence) -> Bool = { $0.kind == .reordered && $0.label == reorder.label }
            atoms.append(IntentDeclaration(text: reorder.dslText, headMatches: head) { divergence, evidence in
                head(divergence)
                    && reorder.position.map {
                        $0.holds(at: divergence.candidateSeq, in: evidence.candidate)
                            && $0.inverted.holds(at: divergence.baselineSeq, in: evidence.baseline)
                    } ?? true
            })
        }
        for move in expectedDomainMigrations {
            let head: @Sendable (Divergence) -> Bool = { divergence in
                divergence.kind == .domainMigration
                    && move.matches(label: divergence.label, from: divergence.fromDomain, to: divergence.toDomain)
                    && move.scope.isAbout(divergence)
            }
            atoms.append(IntentDeclaration(text: move.dslText, headMatches: head) { divergence, evidence in
                head(divergence)
                    && move.scope.map { $0.holds(for: divergence, among: evidence.siblings(of: divergence)) } ?? true
            })
        }
        return atoms
    }
}
