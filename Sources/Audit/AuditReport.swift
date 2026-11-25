import Foundation
import HaruspecTrace

/// What one capture-completeness audit found: the declarations it could not read at all, and the
/// deny-listed channels in the ones it could.
///
/// Both halves are blind spots, and they fail the same way on purpose. "I read the source and found a
/// direct `NotificationCenter.default` post" and "I could not find the source" are different facts
/// about the auditor, but the same fact about the verdict: it cannot claim it saw every channel.
public struct AuditReport: Sendable, Equatable {
    /// Declarations whose source could not be located (see ``SourceResolution/isResolved``).
    public let unresolved: [SourceResolution]
    /// Deny-listed reaches in the sources that were read, gating and non-gating alike.
    public let findings: [ChannelFinding]

    public init(unresolved: [SourceResolution], findings: [ChannelFinding]) {
        self.unresolved = unresolved
        self.findings = findings
    }

    /// Runs the whole audit: resolves each declaration to its source, then lints the sources that
    /// resolved.
    ///
    /// - Parameters:
    ///   - origins: The labels a capture reached, each with the symbol and file it was declared in.
    ///   - root: The directory sources are resolved beneath.
    ///   - rules: The channels to look for; the built-in deny list by default.
    ///   - heldStandIns: The stand-ins the capture held work through, by name; reaches through them
    ///     report without gating.
    /// - Returns: The report: `unresolved` holds the declarations no source was found for, `findings`
    ///   every rule hit in the rest.
    public static func audit(
        origins: some Sequence<TraceOrigin>,
        root: URL,
        rules: [ChannelRule] = ChannelLint.denyList,
        heldStandIns: [String] = []
    ) -> AuditReport {
        let resolutions = SourceResolver(root: root).resolve(origins)
        let held = Set(heldStandIns.compactMap(HeldStandIn.init(rawValue:)))
        return AuditReport(
            unresolved: resolutions.filter { !$0.isResolved },
            findings: ChannelLint(root: root, rules: rules, heldStandIns: held).findings(in: resolutions)
        )
    }

    /// Effects leaving through a channel nothing records — the findings that gate.
    public var bypasses: [ChannelFinding] {
        findings.filter { $0.use == .bypass }
    }

    /// Channels supplied as a default at an injection point. Reported, never gating: the harness
    /// overrides the default, so the escape is only real if the spec fails to inject there — a fact
    /// about the *run*, not the source, so it is checked at run time, never gated here.
    public var injectableDefaults: [ChannelFinding] {
        findings.filter { $0.use == .injectableDefault }
    }

    /// Reaches through a stand-in the capture held work through. Reported, never gating.
    public var held: [ChannelFinding] {
        findings.filter { $0.use == .held }
    }

    /// Nothing left the captured surface, and nothing was unreadable. Only this may leave a green
    /// verdict green.
    public var isClean: Bool {
        unresolved.isEmpty && bypasses.isEmpty
    }

    /// The audit's line on the verdict, as ``Qualification/blindSpots`` carries it: named channels, each
    /// once, plus the declarations that could not be read. An empty array is a *claim* — audited and
    /// clean — which is why it is only ever produced by an audit that actually ran.
    public var blindSpots: [String] {
        var spots = orderedUnique(bypasses.map(\.channel))
        spots += unresolved.compactMap(\.unresolvedDescription)
        return spots
    }

    /// Returns the findings as a reviewer reads them: what gates first, then what merely wants confirming.
    ///
    /// - Returns: The plain-text report, one finding per line; a single "no bypassed channels" line
    ///   when nothing gates.
    public func report() -> String {
        var lines: [String] = []
        for channel in orderedUnique(bypasses.map(\.channel)) {
            lines.append("⚠︎ \(channel)")
            for finding in bypasses where finding.channel == channel {
                lines.append("    \(finding.file):\(finding.line)  \(finding.text)")
            }
        }
        for resolution in unresolved {
            lines.append("⚠︎ unreadable: \(resolution.unresolvedDescription ?? "")")
            lines.append("    \(resolution.origin.label) — no source found for this declaration")
        }
        if lines.isEmpty {
            lines.append("audited — no bypassed channels found")
        }
        let held = held
        if !held.isEmpty {
            lines.append("")
            lines.append("· \(held.count) reach\(held.count == 1 ? "" : "es") through a held stand-in "
                + "(not gating — the capture held this work):")
            for finding in held {
                lines.append("    \(finding.file):\(finding.line)  \(finding.text)")
            }
        }
        let defaults = injectableDefaults
        if !defaults.isEmpty {
            lines.append("")
            lines.append("· \(defaults.count) injectable default\(defaults.count == 1 ? "" : "s") "
                + "(not gating — confirm the spec injects here):")
            for finding in defaults {
                lines.append("    \(finding.file):\(finding.line)  \(finding.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Returns `values` with duplicates dropped, first occurrence winning and order preserved — findings
/// read in file order, and a channel names itself once however many lines reach it.
///
/// - Parameter values: The strings to deduplicate, in reading order.
/// - Returns: Each distinct string once, at its first position.
func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}
