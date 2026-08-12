import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecTrace

// The README disclaimer ("Haruspec is not omniscient"), operationalized per verdict. A green that
// silently missed an effect channel is how the tool loses trust permanently, so every verdict —
// green, red, abstain — states what it exercised, what it varied, and what it could not see. The
// dogfood lesson (PR #5's sibling bug): a per-LINE promo bug was invisible because no probe ever
// produced a multi-line checkout, and *nothing in the green verdict said so*. Each line here is that
// missing sentence for one axis.

/// What a verdict was measured over — the qualification block's stored feeds. The other two lines the
/// block renders (orderings, stability) live on `exploration` and `stability`; this holds the rest.
public struct Qualification: Codable, Sendable, Equatable {
    /// Class labels the golden traces exercised (structural tier), including classes reached
    /// transitively — the same index `SpecPlan.coveredClasses` pins, carried onto the verdict so the
    /// report can say *which* subject the claim scopes to.
    public let coveredClasses: [String]
    /// Operations on the interrogation surface: declared ops on the live differential, the plan's
    /// recorded ops on replay.
    public let operations: Int
    /// Interrogations a full pass drives: generated runs on the live differential, replayable
    /// recorded probes on replay.
    public let probes: Int
    /// Readings per property-varied seam, measured off the golden template (seam → track length).
    /// Zero means the seam was declared but nothing read it — the `unmatchedDomain` story, visible
    /// here as well so the block never implies a swept axis that never moved.
    public let seamPositions: [String: Int]
    /// Effect channels the capture demonstrably could not see. `nil` means the capture-completeness
    /// audit has not run — rendered as "not audited", never as an empty (clean) list. The audit card
    /// fills this in when it lands; until then the placeholder keeps the block from overstating.
    public let blindSpots: [String]?

    public init(
        coveredClasses: [String],
        operations: Int,
        probes: Int,
        seamPositions: [String: Int],
        blindSpots: [String]?
    ) {
        self.coveredClasses = coveredClasses
        self.operations = operations
        self.probes = probes
        self.seamPositions = seamPositions
        self.blindSpots = blindSpots
    }
}

// MARK: - The rendered lines (one vocabulary for report(), markdown, and HTML)

extension SpecVerdict {
    /// The five qualification lines, as label/value pairs every surface renders from — the sticky
    /// comment, the HTML artifact, and the terminal report can't drift apart if they share the source.
    var qualificationEntries: [(label: String, value: String)] {
        [
            (label: "covered", value: coveredEntry),
            (label: "orderings", value: orderingsEntry),
            (label: "seams", value: seamsEntry),
            (label: "NOT seen", value: blindSpotEntry),
            (label: "stability", value: stabilityEntry)
        ]
    }

    /// The additions to the terminal `report()` — only the lines it doesn't already print
    /// (exploration and stability render there via their own lines).
    var qualificationReportLines: [String] {
        [
            "  covered: \(coveredEntry)",
            "  seams: \(seamsEntry)",
            "  blind spots: \(blindSpotEntry)"
        ]
    }

    private var coveredEntry: String {
        let classes = qualification.coveredClasses.isEmpty
            ? "(no structural tier recorded)"
            : qualification.coveredClasses.joined(separator: ", ")
        let ops = qualification.operations
        let probes = qualification.probes
        return "\(classes) — \(ops) op\(ops == 1 ? "" : "s") · \(probes) probe\(probes == 1 ? "" : "s")"
    }

    private var orderingsEntry: String {
        guard !exploration.isExhaustive else {
            return "all \(exploration.orderingsAvailable) explored (exhaustive)"
        }
        let bound = exploration.orderingsAreExact ? "" : "≥"
        var text = "\(exploration.orderingsExplored) sampled of \(bound)\(exploration.orderingsAvailable) available"
        if let fraction = exploration.orderingFraction {
            text += " (\(Exploration.percent(fraction)))"
        }
        return text
    }

    private var seamsEntry: String {
        guard !qualification.seamPositions.isEmpty else {
            return "none declared — no seam value was varied"
        }
        var text = qualification.seamPositions.sorted { $0.key < $1.key }
            .map { seam, positions in
                positions == 0
                    ? "\(seam) (declared, never read)"
                    : "\(seam) (\(positions) position\(positions == 1 ? "" : "s"))"
            }
            .joined(separator: ", ")
        let scheduled = exploration.boundaryEdgesScheduled
        if scheduled > 0 {
            text += " · boundary edges \(exploration.boundaryEdgesCovered) of \(scheduled) scheduled"
            let dropped = scheduled - exploration.boundaryEdgesCovered
            if dropped > 0 {
                text += " (\(dropped) dropped — budget)"
            }
        }
        return text
    }

    private var blindSpotEntry: String {
        guard let blindSpots = qualification.blindSpots else {
            return "not audited — capture completeness is unmeasured; "
                + "effect channels outside the recorded seams may exist"
        }
        return blindSpots.isEmpty
            ? "audited — no blind spots declared"
            : blindSpots.joined(separator: ", ")
    }

    private var stabilityEntry: String {
        guard stability.replays > 1 else {
            return "single replay — reproduction not measured"
        }
        return stability.isStable
            ? "\(stability.replays)/\(stability.replays) identical replays"
            : "\(stability.outcomes.count) distinct outcomes across \(stability.replays) replays"
    }
}

// MARK: - Assembly (the two verify paths)

extension Spec {
    /// The live differential's qualification, measured off the golden template this run just recorded.
    func liveQualification(goldenTrace: Trace, golden: CassetteData, exploration: Exploration) -> Qualification {
        Qualification(
            coveredClasses: structuralClasses(in: [goldenTrace]),
            operations: operations.count,
            probes: exploration.runs,
            seamPositions: seamPositions(in: golden.tracks, varied: seamDomains.keys),
            blindSpots: nil
        )
    }

    /// The replay qualification: the plan already pins the surface — classes, varied seams, and the
    /// golden template all come from it, so the block describes what was recorded, not a re-derivation.
    func replayQualification(of plan: SpecPlan, operations: Int, probes: Int) -> Qualification {
        Qualification(
            coveredClasses: plan.coveredClasses,
            operations: operations,
            probes: probes,
            seamPositions: seamPositions(
                in: plan.probes.first?.cassette.tracks ?? [:],
                varied: plan.variedSeams
            ),
            blindSpots: nil
        )
    }
}

/// The trace-derived class index (`PromoCart.checkout` → `PromoCart`), shared by `record()` and the
/// live differential so the plan's `coveredClasses` and a live verdict's are the same extraction.
func structuralClasses(in traces: some Sequence<Trace>) -> [String] {
    var classes = Set<String>()
    for trace in traces {
        for event in trace.events where event.tier == .structural {
            if let dot = event.label.firstIndex(of: "."), dot != event.label.startIndex {
                classes.insert(String(event.label[..<dot]))
            }
        }
    }
    return classes.sorted()
}

/// Track length per varied seam. A declared seam nothing recorded keeps its entry at zero — absence
/// would hide the unmatched domain from the one block whose job is saying what never moved.
private func seamPositions(in tracks: [String: [CanonicalValue]], varied: some Sequence<String>) -> [String: Int] {
    var positions: [String: Int] = [:]
    for seam in varied {
        positions[seam] = tracks[seam]?.count ?? 0
    }
    return positions
}
