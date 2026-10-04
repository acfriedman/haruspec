import Foundation

/// How two traces are *lined up* before anything is compared — the half of the diff that decides which
/// baseline event corresponds to which candidate event, and what to call the ones that correspond to
/// nothing.
///
/// Split from `Diff.swift` because it is a distinct problem with its own vocabulary: `Diff.swift` says
/// what a divergence *is* and how values are judged, this says which events were even talking about the
/// same thing.
extension BehavioralDiff {
    struct Signature: Hashable {
        let kind: EventKind
        let label: String
        let domain: ConcurrencyDomain

        /// The same event stripped of where it ran — what a domain migration is matched on.
        var ignoringDomain: Signature {
            Signature(kind: kind, label: label, domain: .main)
        }
    }

    /// What the LCS produced: both event lists, their signatures, and which indices it managed to
    /// pair. Grouped because the reconciliation pass needs all six together and none of them apart.
    struct Alignment {
        let baseline: [TraceEvent]
        let candidate: [TraceEvent]
        let baselineSig: [Signature]
        let candidateSig: [Signature]
        let matchedBaseline: Set<Int>
        let matchedCandidate: Set<Int>
    }

    static func signature(_ event: TraceEvent) -> Signature {
        Signature(kind: event.kind, label: event.label, domain: event.domain)
    }

    /// Everything the LCS could not align: an event that moved, one that changed isolation domain, and
    /// the genuine absences left over. Split out of `compare` so that pipeline stays readable — the
    /// classification rules here are the fiddly part and deserve their own frame.
    static func reconcileUnmatched(
        _ alignment: Alignment,
        spec: Tolerance,
        advisory: (TraceEvent) -> Bool,
        into scratch: inout DiffScratch
    ) {
        let (baseline, candidate) = (alignment.baseline, alignment.candidate)
        let (baselineSig, candidateSig) = (alignment.baselineSig, alignment.candidateSig)
        let (matchedBaseline, matchedCandidate) = (alignment.matchedBaseline, alignment.matchedCandidate)
        // 3/4b. Reconcile the unmatched: pair equal signatures as moves, rest are missing/unexpected.
        var unmatchedInsertions = candidate.indices.filter { !matchedCandidate.contains($0) }
        for baselineIndex in baseline.indices where !matchedBaseline.contains(baselineIndex) {
            if let slot = unmatchedInsertions.firstIndex(where: { candidateSig[$0] == baselineSig[baselineIndex] }) {
                let candidateIndex = unmatchedInsertions.remove(at: slot)
                if !spec.isUnordered(label: baseline[baselineIndex].label) {
                    scratch.divergences.append(
                        Divergence(
                            kind: .reordered,
                            label: baseline[baselineIndex].label,
                            baselineSeq: baseline[baselineIndex].seq,
                            candidateSeq: candidate[candidateIndex].seq,
                            detail: "event order changed (baseline #\(baseline[baselineIndex].seq) "
                                + "→ candidate #\(candidate[candidateIndex].seq))",
                            isAdvisory: advisory(baseline[baselineIndex])
                        )
                    )
                }
                // A moved event can still carry a value/timing regression — check it either way.
                compareAligned(
                    baseline[baselineIndex],
                    candidate[candidateIndex],
                    spec: spec,
                    isAdvisory: advisory(baseline[baselineIndex]),
                    into: &scratch
                )
            } else if spec.domainMigration != .ignored,
                      let slot = unmatchedInsertions.firstIndex(where: {
                          candidateSig[$0].ignoringDomain == baselineSig[baselineIndex].ignoringDomain
                      }) {
                // Same event, another isolation domain. Reporting this as one named change rather than
                // a missing/unexpected pair is the whole point: a port that moves work from a dispatch
                // queue to an actor migrates *every* event it touches, and pairs would bury the values
                // — which are what actually say whether behavior survived the move.
                let candidateIndex = unmatchedInsertions.remove(at: slot)
                scratch.divergences.append(
                    Divergence(
                        kind: .domainMigration,
                        label: baseline[baselineIndex].label,
                        baselineSeq: baseline[baselineIndex].seq,
                        candidateSeq: candidate[candidateIndex].seq,
                        detail: "ran on a different domain "
                            + "(\(baseline[baselineIndex].domain) → \(candidate[candidateIndex].domain))",
                        fromDomain: baseline[baselineIndex].domain.description,
                        toDomain: candidate[candidateIndex].domain.description,
                        isAdvisory: advisory(baseline[baselineIndex])
                            || spec.domainMigration == .advisory
                    )
                )
                // The move is reported; the values are still the contract.
                compareAligned(
                    baseline[baselineIndex],
                    candidate[candidateIndex],
                    spec: spec,
                    isAdvisory: advisory(baseline[baselineIndex]),
                    into: &scratch
                )
            } else {
                scratch.divergences.append(
                    Divergence(
                        kind: .missingEvent,
                        label: baseline[baselineIndex].label,
                        baselineSeq: baseline[baselineIndex].seq,
                        candidateSeq: nil,
                        detail: "\(baseline[baselineIndex].kind.rawValue) present in baseline, absent in candidate",
                        isAdvisory: advisory(baseline[baselineIndex])
                    )
                )
            }
        }
        for candidateIndex in unmatchedInsertions {
            scratch.divergences.append(
                Divergence(
                    kind: .unexpectedEvent,
                    label: candidate[candidateIndex].label,
                    baselineSeq: nil,
                    candidateSeq: candidate[candidateIndex].seq,
                    detail: "\(candidate[candidateIndex].kind.rawValue) present in candidate, absent in baseline",
                    isAdvisory: advisory(candidate[candidateIndex])
                )
            )
        }
    }

    /// Aligns two event lists so identical events pair first. A call asked in another order then
    /// pairs with its identical twin and reads as moved, not as every position between it changing.
    ///
    /// - Parameters:
    ///   - baseline: The baseline's events, canonicalized.
    ///   - candidate: The candidate's events, canonicalized.
    /// - Returns: The aligned index pairs, in increasing order; every pair shares a signature.
    ///
    /// An alignment's score counts each pair with equal content above any number of pairs that
    /// share only a signature.
    static func contentFirstAlignment(_ baseline: [TraceEvent], _ candidate: [TraceEvent]) -> [(Int, Int)] {
        let baselineSig = baseline.map(signature), candidateSig = candidate.map(signature)
        let baselineContent = contents(of: baseline), candidateContent = contents(of: candidate)
        let rows = baseline.count, columns = candidate.count
        guard rows > 0, columns > 0 else { return [] }
        // One identical pair outweighs a whole alignment of signature-only pairs.
        let identical = rows + columns + 1
        func weight(_ row: Int, _ column: Int) -> Int {
            guard baselineSig[row] == candidateSig[column] else { return 0 }
            return baselineContent[row] == candidateContent[column] ? identical : 1
        }
        let width = columns + 1
        var table = [Int](repeating: 0, count: (rows + 1) * width)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                let paired = weight(row, column)
                let skip = Swift.max(table[(row + 1) * width + column], table[row * width + column + 1])
                table[row * width + column] = paired > 0
                    ? Swift.max(skip, table[(row + 1) * width + column + 1] + paired)
                    : skip
            }
        }
        var pairs: [(Int, Int)] = []
        var row = 0, column = 0
        while row < rows, column < columns {
            let paired = weight(row, column)
            if paired > 0, table[row * width + column] == table[(row + 1) * width + column + 1] + paired {
                pairs.append((row, column)); row += 1; column += 1
            } else if table[(row + 1) * width + column] >= table[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return pairs
    }

    /// Returns each event's content as alignment compares it: its payload, and for a return the
    /// payload of the call it returns from too, since the same value answers different questions.
    ///
    /// - Parameter events: A trace's events, in order.
    /// - Returns: One content string per event, in the same order.
    private static func contents(of events: [TraceEvent]) -> [String] {
        var open: [String: [String]] = [:]
        return events.map { event in
            let own = event.payload?.canonicalString ?? ""
            switch event.kind {
            case .call:
                open[event.label, default: []].append(own)
                return own
            case .ret:
                return (open[event.label]?.popLast() ?? "") + " → " + own
            default:
                return own
            }
        }
    }

    /// Classic O(n·m) LCS, returning the aligned index pairs in increasing order.
    static func longestCommonSubsequence<T: Equatable>(_ first: [T], _ second: [T]) -> [(Int, Int)] {
        let firstCount = first.count, secondCount = second.count
        guard firstCount > 0, secondCount > 0 else { return [] }
        // One flat allocation rather than `firstCount + 1` row objects. The table is O(E²) `Int`s and is
        // the dominant cost of diffing a chatty trace — nested arrays add a retain/release and a second
        // bounds check to every cell of it.
        let width = secondCount + 1
        var table = [Int](repeating: 0, count: (firstCount + 1) * width)
        for row in stride(from: firstCount - 1, through: 0, by: -1) {
            let rowBase = row * width, nextBase = rowBase + width
            for column in stride(from: secondCount - 1, through: 0, by: -1) {
                table[rowBase + column] = first[row] == second[column]
                    ? table[nextBase + column + 1] + 1
                    : Swift.max(table[nextBase + column], table[rowBase + column + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var row = 0, column = 0
        while row < firstCount, column < secondCount {
            if first[row] == second[column] {
                pairs.append((row, column)); row += 1; column += 1
            } else if table[(row + 1) * width + column] >= table[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return pairs
    }
}
