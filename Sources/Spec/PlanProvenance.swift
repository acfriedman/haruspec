import Foundation

// Record-on-merge's freshness model. A plan is a cache of main's behavior, and this file holds the
// cache-invalidation half: what a recording depended on (its provenance), whether a given diff
// touches that dependency set (staleness), and the four-way partition a reconciliation sweep hands
// the CI job (record / orphaned / fresh). The sweep itself is pure — the git diff arrives as an
// injected closure — so the whole decision surface is testable without a repository.

/// Where a plan was recorded and what the recording executed — the plan's discovered dependency
/// list, in the sense a compiler's depfile discovers headers.
///
/// Stamped by the record-on-merge job after recording (`haruspec stamp`), never by ``BaselinedSpec/record()``
/// itself: both fields are facts about the checkout and the coverage report, which only the job
/// running the recording can see.
public struct PlanProvenance: Codable, Sendable, Equatable {
    /// The commit the recording built and ran — the base of every later freshness diff.
    public var recordedAt: String

    /// Repo-relative source files whose code executed while the golden was captured.
    ///
    /// A doubled collaborator's production files never execute, so they are absent by
    /// measurement — the audit's "collaborator internals are out of scope" doctrine, derived
    /// rather than declared.
    public var coverageFiles: [String]

    public init(recordedAt: String, coverageFiles: [String]) {
        self.recordedAt = recordedAt
        self.coverageFiles = coverageFiles
    }
}

/// Whether one plan still caches main's behavior, judged against the files changed since it was
/// recorded.
public enum PlanStaleness: Equatable, Sendable {
    /// No provenance stamp: the plan was recorded outside the reconciler, so nothing bounds what
    /// may have changed since — treated as stale, and the re-record is what earns the stamp.
    case unstamped
    /// Files the recording executed have changed since `recordedAt`; `overlap` names them.
    case stale(overlap: [String])
    /// Nothing the recording executed has changed — the cache is still exact.
    case fresh
}

public extension SpecPlan {
    /// Returns this plan's staleness against `changedFiles` (repo-relative, as
    /// `git diff --name-only <recordedAt>..HEAD` reports them).
    ///
    /// - Parameter changedFiles: Repo-relative paths changed since the plan's `recordedAt`.
    /// - Returns: ``PlanStaleness/unstamped`` when the plan carries no provenance;
    ///   ``PlanStaleness/stale(overlap:)`` naming the changed files the recording executed, sorted; otherwise
    ///   ``PlanStaleness/fresh``.
    func staleness(changedFiles: some Sequence<String>) -> PlanStaleness {
        guard let provenance else { return .unstamped }
        let covered = Set(provenance.coverageFiles)
        let overlap = Set(changedFiles).intersection(covered).sorted()
        return overlap.isEmpty ? .fresh : .stale(overlap: overlap)
    }
}

/// The reconciliation a record-on-merge sweep decided: which specs to record, which plans to
/// delete, which to leave alone — with a reason per decision the job log and the page can print.
///
/// Serialized as the sweep's stdout contract (`haruspec sweep`), so field names are read by CI.
public struct PlanSweep: Codable, Equatable, Sendable {
    /// Specs with a committed plan that no longer caches main: re-record, guarding the delta
    /// against the merged PRs' declarations first (the plan exists, so the guard has a baseline).
    public var stale: [String]
    /// Specs the census declares that have no committed plan: record for the first time. No
    /// delta guard is possible — only the merge-had-a-green-check guard protects a birth.
    public var births: [String]
    /// Committed plans whose spec the census no longer declares: delete.
    public var orphaned: [String]
    /// Committed plans the current engine cannot read (a schema bump, a corrupt artifact):
    /// record fresh, unguarded — no readable baseline exists to attribute a delta against.
    public var unreadable: [String]
    /// Plans whose dependency set the diff never touched: leave untouched, commit nothing.
    public var fresh: [String]
    /// Why each non-fresh spec landed in its bucket, keyed by spec name.
    public var reasons: [String: String]
    /// Each stamped plan's `recordedAt`, keyed by spec name — the per-plan base of the guard
    /// window (which merges must have been seen green).
    public var recordedAt: [String: String]
    /// Whether the sweep could not rule out catalog changes and a census run should decide.
    /// Always false once a census is supplied; meaningful only without one.
    public var censusAdvised: Bool

    /// Whether the reconciler has anything to do beyond reporting.
    public var hasWork: Bool {
        !stale.isEmpty || !births.isEmpty || !orphaned.isEmpty || !unreadable.isEmpty || censusAdvised
    }

    /// The human rendering (one line per spec, reason attached) — the job log's view of the
    /// decision, beside the JSON the workflow parses.
    public var summaryLines: String {
        var lines: [String] = []
        for (bucket, specs) in [
            ("stale", stale),
            ("birth", births),
            ("orphaned", orphaned),
            ("unreadable", unreadable),
            ("fresh", fresh)
        ] {
            for spec in specs {
                let reason = reasons[spec].map { " — \($0)" } ?? ""
                lines.append("\(bucket): \(spec)\(reason)")
            }
        }
        if censusAdvised {
            lines.append("census advised — the catalog may have changed; run a census and re-sweep")
        }
        if lines.isEmpty {
            lines.append("no committed plans")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public extension PlanSweep {
    /// Runs the sweep: partitions `plans` (spec name → plan) by staleness, and — when `census`
    /// names the declared specs — adds births and orphans from the catalog-vs-plans gap.
    ///
    /// - Parameters:
    ///   - plans: Every committed plan, paired with its spec name.
    ///   - census: Spec names the app's catalog declares; `nil` means no census ran.
    ///   - testSources: Repo-relative prefix under which spec declarations live; `nil` when unknown.
    ///   - changedFiles: Returns `git diff --name-only <recordedAt>..HEAD` for a stamped plan's
    ///     `recordedAt`; throws when the range is unanswerable (unknown commit, shallow history).
    /// - Returns: The decision, with each plan in exactly one of `fresh` or `stale` unless the census
    ///   orphans it. A plan whose range is unanswerable is stale fail-safe: freshness is a proof, and an
    ///   unanswerable range proves nothing. Births and orphans are judged only with a census; without
    ///   one, `censusAdvised` is set when a plan is unstamped, there are no plans, or a changed file under
    ///   `testSources` lies outside every plan's coverage — where a new spec necessarily lands.
    static func run(
        plans: [(spec: String, plan: SpecPlan)],
        census: [String]?,
        testSources: String?,
        changedFiles: (String) throws -> [String]
    ) -> PlanSweep {
        var sweep = PlanSweep(
            stale: [],
            births: [],
            orphaned: [],
            unreadable: [],
            fresh: [],
            reasons: [:],
            recordedAt: [:],
            censusAdvised: false
        )
        let (allChanged, allCovered) = sweep.assess(plans, changedFiles: changedFiles)
        sweep.reconcileCatalog(
            census: census,
            planned: Set(plans.map(\.spec)),
            testSources: testSources,
            uncoveredChanges: allChanged.subtracting(allCovered)
        )
        return sweep
    }

    /// Buckets each plan by staleness into this sweep, and returns the changed- and covered-file unions
    /// the census advisement reads.
    ///
    /// - Parameters:
    ///   - plans: Every committed plan, paired with its spec name.
    ///   - changedFiles: Returns the repo-relative files changed since a stamped plan's `recordedAt`;
    ///     throws when that range is unanswerable.
    /// - Returns: Every file changed since any stamped plan's `recordedAt` whose range was answerable, and
    ///   every file any stamped plan's recording executed.
    private mutating func assess(
        _ plans: [(spec: String, plan: SpecPlan)],
        changedFiles: (String) throws -> [String]
    ) -> (allChanged: Set<String>, allCovered: Set<String>) {
        var allChanged: Set<String> = []
        var allCovered: Set<String> = []
        for (spec, plan) in plans.sorted(by: { $0.spec < $1.spec }) {
            guard let provenance = plan.provenance else {
                stale.append(spec)
                reasons[spec] = "unstamped — recorded outside the reconciler; "
                    + "re-recording earns the provenance stamp"
                censusAdvised = true
                continue
            }
            recordedAt[spec] = provenance.recordedAt
            allCovered.formUnion(provenance.coverageFiles)
            do {
                let changed = try changedFiles(provenance.recordedAt)
                if case let .stale(overlap) = plan.staleness(changedFiles: changed) {
                    stale.append(spec)
                    reasons[spec] = "covered sources changed since \(provenance.recordedAt): "
                        + overlap.joined(separator: ", ")
                } else {
                    fresh.append(spec)
                }
                allChanged.formUnion(changed)
            } catch {
                stale.append(spec)
                reasons[spec] = "recordedAt \(provenance.recordedAt) is unanswerable "
                    + "(\(error)) — freshness cannot be proven, re-record"
            }
        }
        return (allChanged, allCovered)
    }

    /// Decides births and orphans from the census, or — without one — whether a census is advised.
    ///
    /// - Parameters:
    ///   - census: Spec names the app's catalog declares; `nil` means no census ran.
    ///   - planned: Spec names with a committed plan.
    ///   - testSources: Repo-relative prefix under which spec declarations live; `nil` when unknown.
    ///   - uncoveredChanges: Changed repo-relative files no stamped plan's recording executed.
    private mutating func reconcileCatalog(
        census: [String]?,
        planned: Set<String>,
        testSources: String?,
        uncoveredChanges: Set<String>
    ) {
        if let census {
            let declared = Set(census)
            births = declared.subtracting(planned).sorted()
            for spec in births {
                reasons[spec] = "declared by the census with no committed plan"
            }
            orphaned = planned.subtracting(declared).sorted()
            for spec in orphaned {
                reasons[spec] = "committed plan for a spec the census no longer declares"
            }
            // A deleted spec's plan is both "its covered file changed" and "no longer declared";
            // orphaned wins — there is no suite left to replay or re-record.
            stale.removeAll(where: Set(orphaned).contains)
            unreadable.removeAll(where: Set(orphaned).contains)
            fresh.removeAll(where: Set(orphaned).contains)
            censusAdvised = false
        } else if planned.isEmpty {
            censusAdvised = true
        } else if let testSources {
            // A file no plan's recording ever executed, changed under the spec-declaration tree:
            // possibly a new or deleted spec, which only a census can decide.
            censusAdvised = censusAdvised
                || uncoveredChanges.contains { $0.hasPrefix(testSources) }
        }
    }
}
