import Foundation
import HaruspecCore
import HaruspecSeams

// What a red replay saw beyond the first case that failed. The sweep used to stop at its first
// divergent probe and report that one — whichever the schedule happened to reach first, which on
// a derived spec is the golden template: the declared order at middle-of-the-road values, and
// sometimes a run that undoes itself (add, then remove the same item). A verdict anchored to it
// pinned `.to(0)` and disclosed an empty cart. Now the sweep keeps walking for a bounded window,
// keeps every failing case, reports the most informative one, and derives its offer from all of
// them.

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

/// The failing cases a red replay walked: every divergent probe within the window after the first,
/// and how far the window reached.
public struct FailingCases: Codable, Sendable, Equatable {
    /// Every failing case, in sweep order. The verdict's own diff and counterexample are the
    /// richest of these, not the first.
    public var probes: [DivergentProbe]
    /// Probes replayed after the first failure, failing or not — the window's actual reach, so a
    /// report can say "8 failing cases among the 64 checked after the first".
    public var walkedAfterFirst: Int

    public init(probes: [DivergentProbe], walkedAfterFirst: Int) {
        self.probes = probes
        self.walkedAfterFirst = walkedAfterFirst
    }

    /// The case the verdict reports: the most informative, earliest on a tie.
    public var richest: DivergentProbe? {
        probes.max { lhs, rhs in lhs.richness < rhs.richness }
            .flatMap { best in probes.first { $0.richness == best.richness } }
    }

    /// Every gating divergence across every failing case — what the offer is derived from.
    public var gatingDivergences: [Divergence] {
        probes.flatMap { $0.divergences.filter(\.isGating) }
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
