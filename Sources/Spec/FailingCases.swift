import Foundation
import HaruspecCore
import HaruspecSeams

// What a red sweep saw beyond the case it reports. The sweep used to stop at its first divergent
// probe, and later behind a 64-probe window. Both hid bugs: one bug that fails nearly every probe
// ends the sweep before a quieter one is reached, so fixing the first only uncovers the next. Now
// a red sweep walks every probe, keeps every failing case, reports the most informative one, and
// lists what the others found that it does not show.

/// One failing case: the probe that was replayed and what diverged in it (classified).
public struct DivergentProbe: Codable, Sendable, Equatable {
    public var ordering: [String]
    public var inputs: CassetteData
    public var divergences: [Divergence]

    public init(ordering: [String], inputs: CassetteData, divergences: [Divergence]) {
        self.ordering = ordering
        self.inputs = inputs
        self.divergences = divergences
    }

    /// How much a reader learns from this case: a value mismatch whose new value is something (not
    /// null, zero, or empty) counts double, every other gating divergence once. The empty-cart run
    /// scores low on purpose — its divergences are all `null → 0`.
    var richness: Int {
        divergences.filter(\.isGating).reduce(0) { score, divergence in
            score + (divergence.kind == .valueMismatch && divergence.candidateValue?.isInformative == true ? 2 : 1)
        }
    }
}

/// The failing cases a red sweep walked: every divergent probe, and how many probes followed the
/// first.
public struct FailingCases: Codable, Sendable, Equatable {
    /// Every failing case, in sweep order. The verdict's own diff and counterexample are the
    /// richest of these, not the first.
    public var probes: [DivergentProbe]
    /// Probes walked after the first failure, failing or not, so a report can say "8 failing cases
    /// among the 64 checked from the first on".
    public var walkedAfterFirst: Int

    public init(probes: [DivergentProbe], walkedAfterFirst: Int) {
        self.probes = probes
        self.walkedAfterFirst = walkedAfterFirst
    }

    /// The case the verdict reports: the most informative, earliest on a tie.
    public var richest: DivergentProbe? {
        richestIndex.map { probes[$0] }
    }

    /// Where `richest` sits in `probes`, so a sweep can pick out the run that produced it.
    var richestIndex: Int? {
        guard let best = probes.map(\.richness).max() else {
            return nil
        }
        return probes.firstIndex { $0.richness == best }
    }

    /// Every gating divergence across every failing case — what the offer is derived from.
    public var gatingDivergences: [Divergence] {
        probes.flatMap { $0.divergences.filter(\.isGating) }
    }

    /// The gating divergences other failing cases found that `reported` does not show, one per
    /// finding, in sweep order — the bugs a single reported case would otherwise hide.
    ///
    /// - Parameter reported: The divergences of the case the verdict reports.
    /// - Returns: The first divergence seen for each finding absent from `reported`.
    public func unreported(beside reported: [Divergence]) -> [Divergence] {
        var seen = Set(reported.map(\.findingKey))
        return gatingDivergences.filter { seen.insert($0.findingKey).inserted }
    }
}

extension Divergence {
    /// What makes two divergences the same finding across cases: where it happened and what kind of
    /// change it was, without the values, event numbers, or op that differ from case to case.
    var findingKey: [String?] {
        [kind.rawValue, label, field, fromDomain, toDomain]
    }
}

/// Where a declared change was first seen to hold: the declaration's spelling, the divergence it
/// absorbed, and the case that produced it — so a green-by-declaration verdict shows what each
/// declaration actually excused, not only that it excused something.
public struct IntentObservation: Codable, Sendable, Equatable {
    public var declaration: String
    public var divergence: Divergence
    public var ordering: [String]
    public var inputs: CassetteData

    public init(declaration: String, divergence: Divergence, ordering: [String], inputs: CassetteData) {
        self.declaration = declaration
        self.divergence = divergence
        self.ordering = ordering
        self.inputs = inputs
    }
}

extension CanonicalValue {
    /// A value a reader learns something from: not null, not a numeric zero, not an empty string.
    var isInformative: Bool {
        switch self {
        case .null: false
        case let .int(int): int != 0
        case let .double(double): double != 0
        case let .string(string): !string.isEmpty
        case .bool, .array, .object: true
        }
    }
}
