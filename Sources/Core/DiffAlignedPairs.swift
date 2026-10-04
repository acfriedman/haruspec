import Foundation

extension BehavioralDiff {
    static func compareAligned(
        _ baseline: TraceEvent,
        _ candidate: TraceEvent,
        spec: Tolerance,
        isAdvisory: Bool,
        into scratch: inout DiffScratch
    ) {
        // Every matcher funnels its pairs through here, so this is where the alignment is recorded.
        scratch.alignedPairs.append((baseline, candidate))
        for mismatch in valueDivergences(
            baseline.payload ?? .null,
            candidate.payload ?? .null,
            path: "",
            spec: spec
        ) {
            scratch.divergences.append(
                Divergence(
                    kind: .valueMismatch,
                    label: baseline.label,
                    baselineSeq: baseline.seq,
                    candidateSeq: candidate.seq,
                    detail: mismatch.detail,
                    field: mismatch.path,
                    baselineValue: mismatch.baseline,
                    candidateValue: mismatch.candidate,
                    isAdvisory: isAdvisory
                )
            )
        }
        scratch.divergences += senderDivergences(baseline, candidate, isAdvisory: isAdvisory)
        if let budget = spec.timingBudget(for: baseline.label),
           let base = baseline.durationTicks, let cand = candidate.durationTicks, cand - base > budget {
            scratch.divergences.append(
                Divergence(
                    kind: .timingRegression,
                    label: baseline.label,
                    baselineSeq: baseline.seq,
                    candidateSeq: candidate.seq,
                    detail: "duration \(base)→\(cand) ticks exceeds budget +\(budget) (Δ=\(cand - base))",
                    isAdvisory: isAdvisory
                )
            )
        }
    }

    /// Returns the divergence of a notification posted with no sender where the other side named
    /// one. Observers filter by sender, so the absence is a change they see.
    ///
    /// - Parameters:
    ///   - baseline: The baseline's event.
    ///   - candidate: The candidate's event aligned with it.
    ///   - isAdvisory: Whether a divergence on this pair reports without gating.
    /// - Returns: One `valueMismatch` on the field `object`, or none when the senders agree or the
    ///   events are not notifications.
    ///
    /// Presence alone is compared: symbolic ids number in first-seen order, which a projection may
    /// legitimately reorder.
    static func senderDivergences(_ baseline: TraceEvent, _ candidate: TraceEvent, isAdvisory: Bool) -> [Divergence] {
        guard baseline.kind == .notification, (baseline.subject == nil) != (candidate.subject == nil) else {
            return []
        }
        let sender = { (event: TraceEvent) in event.subject == nil ? "nil" : "an object" }
        return [Divergence(
            kind: .valueMismatch,
            label: baseline.label,
            baselineSeq: baseline.seq,
            candidateSeq: candidate.seq,
            detail: "sender: baseline=\(sender(baseline)) candidate=\(sender(candidate))",
            field: "object",
            baselineValue: .string(sender(baseline)),
            candidateValue: .string(sender(candidate)),
            isAdvisory: isAdvisory
        )]
    }
}
