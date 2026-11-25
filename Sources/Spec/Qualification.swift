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
    /// transitively — the same index ``SpecPlan/coveredClasses`` pins, carried onto the verdict so the
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
    /// audit has not run — rendered as "not audited", never as an empty (clean) list, so an unaudited
    /// verdict cannot overstate.
    ///
    /// Filled via ``noting(blindSpots:)`` by the audit that ran.
    public let blindSpots: [String]?
    /// Where the covered labels are declared, collected from the instrumentation as it ran (see
    /// `TraceOrigin`). This is the audit's denominator made explicit: the files a completeness check
    /// has to read, and — where `source` is nil — the reached behavior it structurally cannot read.
    public let origins: [TraceOrigin]
    /// Seams whose domains the engine defaulted (a derived op's argument) rather than the author
    /// declared. Rendered per seam, so a green over a defaulted surface says so — the honesty line
    /// that makes derived specs safe to offer. `nil` on verdicts serialized before the field existed;
    /// rendering treats that as none.
    public let derivedDefaults: [String]?
    /// The observed-property line: which properties were snapshot at the end of every capture, whose
    /// end-state values gate. `nil` when the spec observes no properties.
    public let observedProperties: String?
    /// The stand-ins the capture held work through (`scheduler`, `operationQueue`), for the audit.
    ///
    /// The audit reads it to tell a reach through one from a reach around the capture. `nil` on
    /// verdicts serialized before the field existed; the audit treats that as none, so they still gate.
    public let heldStandIns: [String]?

    public init(
        coveredClasses: [String],
        operations: Int,
        probes: Int,
        seamPositions: [String: Int],
        blindSpots: [String]?,
        origins: [TraceOrigin] = [],
        derivedDefaults: [String]? = nil,
        observedProperties: String? = nil,
        heldStandIns: [String]? = nil
    ) {
        self.coveredClasses = coveredClasses
        self.operations = operations
        self.probes = probes
        self.seamPositions = seamPositions
        self.blindSpots = blindSpots
        self.origins = origins
        self.derivedDefaults = derivedDefaults
        self.observedProperties = observedProperties
        self.heldStandIns = heldStandIns
    }

    /// The same qualification with the origins one verification collected. Assembled here rather than
    /// at `liveQualification` because the surface is resolved off the *golden* template, before a
    /// candidate has run — and a candidate's sources are the ones a PR audit most needs to name.
    ///
    /// - Parameters:
    ///   - origins: Where the covered labels are declared.
    ///   - heldStandIns: The stand-ins the capture held work through.
    /// - Returns: This qualification with both.
    func noting(origins: [TraceOrigin], heldStandIns: [String]) -> Qualification {
        Qualification(
            coveredClasses: coveredClasses,
            operations: operations,
            probes: probes,
            seamPositions: seamPositions,
            blindSpots: blindSpots,
            origins: origins,
            derivedDefaults: derivedDefaults,
            observedProperties: observedProperties,
            heldStandIns: heldStandIns
        )
    }

    /// The same qualification with what the capture-completeness audit found. Only an audit that ran
    /// calls this — the nil placeholder is how a verdict says nobody looked.
    func noting(blindSpots: [String]) -> Qualification {
        Qualification(
            coveredClasses: coveredClasses,
            operations: operations,
            probes: probes,
            seamPositions: seamPositions,
            blindSpots: blindSpots,
            origins: origins,
            derivedDefaults: derivedDefaults,
            observedProperties: observedProperties,
            heldStandIns: heldStandIns
        )
    }
}

// MARK: - The rendered lines (one vocabulary for report(), markdown, and HTML)

extension SpecVerdict {
    /// The five qualification lines, as label/value pairs every surface renders from — the sticky
    /// comment, the HTML artifact, and the terminal report can't drift apart if they share the source.
    var qualificationEntries: [(label: String, value: String)] {
        var entries = [
            (label: "covered", value: coveredEntry),
            (label: "declared in", value: sourcesEntry),
            (label: "orderings", value: orderingsEntry),
            (label: "seams", value: seamsEntry)
        ]
        if let properties = qualification.observedProperties {
            entries.append((label: "properties", value: properties))
        }
        entries.append((label: "NOT seen", value: blindSpotEntry))
        entries.append((label: "stability", value: stabilityEntry))
        return entries
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

    private var stabilityEntry: String {
        if let selfCheck = stability.baselineSelfCheck {
            return selfCheck.isEmpty
                ? "single run — the baseline reproduced itself on the failing input"
                : "the baseline disagreed with itself on the failing input"
        }
        guard stability.replays > 1 else {
            return "single replay — reproduction not measured"
        }
        return stability.isStable
            ? "\(stability.replays)/\(stability.replays) identical replays"
            : "\(stability.outcomes.count) distinct outcomes across \(stability.replays) replays"
    }

    /// The additions to the terminal ``report()`` — only the lines it doesn't already print
    /// (exploration and stability render there via their own lines).
    var qualificationReportLines: [String] {
        var lines = [
            "  covered: \(coveredEntry)",
            "  declared in: \(sourcesEntry)",
            "  seams: \(seamsEntry)"
        ]
        if let properties = qualification.observedProperties {
            lines.append("  properties: \(properties)")
        }
        lines.append("  blind spots: \(blindSpotEntry)")
        return lines
    }

    private var coveredEntry: String {
        let classes = qualification.coveredClasses.isEmpty
            ? "(no structural tier recorded)"
            : qualification.coveredClasses.joined(separator: ", ")
        let ops = qualification.operations
        let probes = qualification.probes
        return "\(classes) — \(ops) op\(ops == 1 ? "" : "s") · \(probes) probe\(probes == 1 ? "" : "s")"
    }

    /// Which sources the covered labels came from — grouped by label, because the interesting case is
    /// exactly the one that made a name search useless: several declarations answering to one label.
    private var sourcesEntry: String {
        guard !qualification.origins.isEmpty else {
            return "unregistered — no instrumented method ran under capture"
        }
        let byLabel = Dictionary(grouping: qualification.origins, by: \.label)
        return byLabel.keys.sorted().map { label in
            "\(label) ← \(byLabel[label, default: []].map(\.declarationEntry).joined(separator: ", "))"
        }
        .joined(separator: " · ")
    }

    private var seamsEntry: String {
        guard !qualification.seamPositions.isEmpty else {
            return "none declared — no seam value was varied"
        }
        let derived = Set(qualification.derivedDefaults ?? [])
        var text = qualification.seamPositions.sorted { $0.key < $1.key }
            .map { seam, positions in
                var notes = positions == 0
                    ? ["declared, never read"]
                    : ["\(positions) position\(positions == 1 ? "" : "s")"]
                if derived.contains(seam) {
                    notes.append("derived default")
                }
                return "\(seam) (\(notes.joined(separator: " · ")))"
            }
            .joined(separator: ", ")
        let scheduled = exploration.boundaryEdgesScheduled
        if scheduled > 0 {
            text += " · boundary edges \(exploration.boundaryEdgesCovered) of \(scheduled) scheduled"
            let dropped = scheduled - exploration.boundaryEdgesCovered
            if dropped > 0 {
                text += " (\(dropped) dropped — budget)"
            }
            text += " · \(exploration.combinedVariantsCovered) combined (every seam at once)"
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
}

// MARK: - Assembly (the two verify paths)

extension Spec {
    /// The live differential's qualification, measured off the golden template this run just recorded.
    /// Packaged sweeps the golden earned count as varied — and as derived, since the engine supplied them.
    func liveQualification(goldenTrace: Trace, golden: CassetteData, exploration: Exploration) -> Qualification {
        let sweeps = resourceSweeps(reaching: golden.tracks.keys)
        return Qualification(
            coveredClasses: structuralClasses(in: [goldenTrace]),
            operations: operations.count,
            probes: exploration.runs,
            seamPositions: seamPositions(in: golden.tracks, varied: Set(seamDomains.keys).union(sweeps.keys)),
            blindSpots: nil,
            derivedDefaults: derivedDefaultSeams.union(sweeps.keys).sorted(),
            observedProperties: observedPropertiesEntry
        )
    }

    /// The replay qualification: the plan already pins the surface — classes, varied seams, and the
    /// golden template all come from it, so the block describes what was recorded, not a re-derivation.
    /// Derived-ness comes from the spec value itself — specs are code, present at replay, so nothing
    /// is stored to drift.
    func replayQualification(of plan: SpecPlan, operations: Int, probes: Int) -> Qualification {
        let goldenTracks = plan.probes.first?.cassette.tracks ?? [:]
        return Qualification(
            coveredClasses: plan.coveredClasses,
            operations: operations,
            probes: probes,
            seamPositions: seamPositions(
                in: goldenTracks,
                varied: plan.variedSeams
            ),
            blindSpots: nil,
            derivedDefaults: derivedDefaultSeams.union(resourceSweeps(reaching: goldenTracks.keys).keys).sorted(),
            observedProperties: observedPropertiesEntry
        )
    }

    /// The properties line: the observed labels, whose end-state snapshots gate; `nil` when the spec
    /// observes none.
    var observedPropertiesEntry: String? {
        guard !observedProperties.isEmpty else {
            return nil
        }
        return "\(observedProperties.map(\.label).sorted().joined(separator: ", ")) — snapshots gate"
    }
}

/// Returns the trace-derived class index (``PromoCart/checkout`` → `PromoCart`). ``BaselinedSpec/record()``
/// and the live differential share it, so the plan's `coveredClasses` and a live verdict's are the same
/// extraction.
///
/// - Parameter traces: The traces to index, from any number of captures.
/// - Returns: The class names, sorted and without repeats: each structural event's label up to its
///   first dot, skipping a label with no class before the dot.
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
