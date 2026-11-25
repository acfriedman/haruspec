import Foundation

/// How much of a change's *declared behavioral surface* a replay actually exercised under
/// held-identical inputs — the number reported alongside every verdict.
///
/// Deliberately **seam-agnostic**: `SeamMiss` (an unrecorded interaction during replay) is only one
/// source — static seam-crossing analysis (`blindSpots`) and property-based breadth (`domainExercised`)
/// land in the same model, so nothing here mentions cassettes — `HaruspecSeams` builds a `Coverage`
/// from a `Cassette` and hands it in.
///
/// The point of the model is soundness: a false `EQUIVALENT` is the one catastrophic outcome, so a
/// coverage gap **downgrades** an otherwise-equivalent verdict to `CANNOT-VERIFY` (see
/// ``VerificationResult/resolve``) rather than letting it pass. Coverage is *reported*, never assumed —
/// `EQUIVALENT` over 20% of the surface is nearly worthless; over 95% is the product.
public struct Coverage: Codable, Sendable, Equatable {
    /// Why a declared boundary isn't covered.
    public enum GapReason: String, Codable, Sendable {
        /// Replay reached the boundary but the recording was exhausted / had no entry, so it fell back
        /// to a *live* read. Isolation broke: the environment was not held identical, so an EQUIVALENT
        /// here can't be trusted.
        ///
        /// This is the hard `CANNOT-VERIFY` trigger.
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
        /// A covered declaration reaches an effect channel nothing records — a direct
        /// `NotificationCenter.default` post, a `Timer`, a Combine publisher. The capture-completeness
        /// audit finds these statically; the `boundary` is the channel it names.
        ///
        /// The hardest trigger of the three, because it is the only one where the *diff itself* is
        /// silent: an unrecorded seam read at least happened during a replay we watched, whereas
        /// effects leaving this way never entered either trace, so nothing about the comparison looks
        /// wrong. Declarable as an accepted blind spot (`Accepts(uncaptured:)`), which is the one way
        /// back to green — and it stays named on the report.
        case bypassedChannel
        /// A covered declaration whose source the audit could not read at all: no file found for the
        /// stamped `#fileID` or the wrapped class. Different fact about the auditor than
        /// `bypassedChannel`, same fact about the verdict — it cannot claim it saw every channel — so
        /// it fails the same way.
        ///
        /// The `boundary` names the declaration.
        case unauditableSource
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
    /// the *reported* evidence behind one.
    ///
    /// Empty for a single-cassette replay (point coverage).
    public var domainExercised: [String]

    /// Sorts its inputs so the value is deterministic regardless of how the adapter assembled it.
    ///
    /// - Parameters:
    ///   - declared: The boundaries the harness knew about; empty when the surface is unknown.
    ///   - exercised: The declared boundaries the replay exercised cleanly.
    ///   - gaps: The boundaries that aren't covered, each with its reason.
    ///   - domainExercised: The declared boundaries exercised over a generated value domain; empty for
    ///     a single-cassette replay.
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

    /// The fraction of the declared surface exercised over a generated value domain rather than at a
    /// single recorded point, or `nil` when the surface is unknown. A single cassette reports 0 here
    /// and property-based breadth raises it, while `fraction` stays the boundary/isolation number.
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

    /// Effect channels a covered declaration reaches around the recorder, and declarations whose
    /// source could not be read — the capture-completeness audit's gating findings. Empty on a run
    /// where the audit never ran, which is why ``Qualification/blindSpots`` (nil = not audited) is what
    /// the report reads: coverage says whether anything gates, the qualification says whether anyone
    /// looked.
    public var blindSpots: [Gap] {
        gaps.filter { $0.reason == .bypassedChannel || $0.reason == .unauditableSource }
    }

    /// Whether an `EQUIVALENT` diff can be trusted over this coverage: the surface is known, no
    /// boundary fell back to live, no declared domain went unmatched, and the audit found no blind
    /// spot. Any such gap downgrades the verdict to `CANNOT-VERIFY`, whereas a low but gap-free
    /// fraction is reported, not gated.
    public var trustsEquivalent: Bool {
        !declared.isEmpty && unrecordedReach.isEmpty && unmatchedDomains.isEmpty && blindSpots.isEmpty
    }

    /// Creates the coverage of an unknown surface: nothing declared, exercised, or gapped. It never
    /// trusts an `EQUIVALENT` verdict, since an empty `declared` is how the model spells "no registry".
    public init() {
        declared = []
        exercised = []
        gaps = []
        domainExercised = []
    }
}
