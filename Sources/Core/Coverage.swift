import Foundation

/// How much of a change's *declared behavioral surface* a replay actually exercised under
/// held-identical inputs — the number reported alongside every verdict.
///
/// Deliberately **seam-agnostic**: `SeamMiss` (an unrecorded interaction during replay) is only its
/// *first* source. The same model later absorbs static seam-crossing analysis and property-based
/// breadth, so nothing here mentions cassettes — `HaruspecSeams` builds a `Coverage` from a `Cassette`
/// and hands it in.
///
/// The point of the model is soundness: a false `EQUIVALENT` is the one catastrophic outcome, so a
/// coverage gap **downgrades** an otherwise-equivalent verdict to `CANNOT-VERIFY` (see
/// `VerificationResult.resolve`) rather than letting it pass. Coverage is *reported*, never assumed —
/// `EQUIVALENT` over 20% of the surface is nearly worthless; over 95% is the product.
public struct Coverage: Codable, Sendable, Equatable {
    /// Why a declared boundary isn't covered.
    public enum GapReason: String, Codable, Sendable {
        /// Replay reached the boundary but the recording was exhausted / had no entry, so it fell back
        /// to a *live* read. Isolation broke: the environment was not held identical, so an EQUIVALENT
        /// here can't be trusted. This is the hard `CANNOT-VERIFY` trigger.
        case unrecorded
        /// A declared boundary the replay never reached this run. Lowers the exercised fraction but is
        /// not a hard trigger — we simply didn't test that path (v1 policy; a fraction threshold is
        /// future work).
        case unexercised
        /// A *value domain* was declared for a seam key nothing ever read, so the domain applied to
        /// nothing. The run swept a surface the spec claims it varied, which is the one shape of false
        /// negative this engine exists not to produce — so it is a hard `CANNOT-VERIFY` trigger like
        /// `unrecorded`, not a fraction adjustment.
        ///
        /// A typo'd key is the usual cause. A seam read only on a branch the golden run didn't take is
        /// the honest one, and the verdict is still right there: that domain varied nothing.
        case unmatchedDomain
    }

    /// One uncovered boundary.
    public struct Gap: Codable, Sendable, Equatable {
        public var boundary: String
        /// The call ordinal at which the miss occurred (`.unrecorded` only).
        public var ordinal: Int?
        public var reason: GapReason

        public init(boundary: String, ordinal: Int? = nil, reason: GapReason) {
            self.boundary = boundary
            self.ordinal = ordinal
            self.reason = reason
        }
    }

    /// The declared coverage map — the boundaries the harness knew about (the seam registry, or, by
    /// default, the seams the golden run recorded). **Empty means the surface is unknown**, and an
    /// unknown surface is never trusted (see `trustsEquivalent`).
    public var declared: [String]

    /// Declared boundaries the replay exercised cleanly: at least one recorded hit and zero misses.
    public var exercised: [String]

    /// The boundaries that aren't covered, and why.
    public var gaps: [Gap]

    /// Declared boundaries exercised over a *generated value domain* (property-based breadth), not just
    /// at their single recorded value. **Additive and report-only**: it never relaxes `trustsEquivalent`
    /// (a sampled domain isn't a proof), so it can't manufacture a false `EQUIVALENT` — it strengthens
    /// the *reported* evidence behind one. Empty for a single-cassette replay (point coverage).
    public var domainExercised: [String]

    /// Sorts its inputs so the value is deterministic regardless of how the adapter assembled it.
    public init(declared: [String], exercised: [String], gaps: [Gap], domainExercised: [String] = []) {
        self.declared = declared.sorted()
        self.exercised = exercised.sorted()
        self.gaps = gaps.sorted {
            ($0.boundary, $0.ordinal ?? -1) < ($1.boundary, $1.ordinal ?? -1)
        }
        self.domainExercised = domainExercised.sorted()
    }

    /// The fraction of the declared surface exercised cleanly — `nil` when the surface is unknown (no
    /// declared registry). This is the number to report next to the verdict.
    public var fraction: Double? {
        declared.isEmpty ? nil : Double(exercised.count) / Double(declared.count)
    }

    /// The fraction of the declared surface exercised over a value *domain* (property gen), not merely at
    /// a single point — `nil` when the surface is unknown. A single cassette reports 0 here; property-based
    /// breadth raises it. Distinct from `fraction`, which is boundary/isolation coverage.
    public var domainFraction: Double? {
        declared.isEmpty ? nil : Double(domainExercised.count) / Double(declared.count)
    }

    /// Gaps where replay fell back to live input — the hard signal that isolation broke.
    public var unrecordedReach: [Gap] {
        gaps.filter { $0.reason == .unrecorded }
    }

    /// Declared domains that matched no seam anything read — the signal that a sweep the spec claims
    /// never happened at all.
    public var unmatchedDomains: [Gap] {
        gaps.filter { $0.reason == .unmatchedDomain }
    }

    /// Can an `EQUIVALENT` diff be *trusted* over this coverage? Only when the surface is known and no
    /// boundary fell back to live. v1 hard rule: unrecorded reach downgrades to `CANNOT-VERIFY`; a low
    /// but gap-free fraction is reported, not gated (a declared `CoveragePolicy` threshold is future
    /// work). An unknown surface (no registry) is never trusted.
    public var trustsEquivalent: Bool {
        !declared.isEmpty && unrecordedReach.isEmpty && unmatchedDomains.isEmpty
    }

    public init() {
        declared = []
        exercised = []
        gaps = []
        domainExercised = []
    }
}
