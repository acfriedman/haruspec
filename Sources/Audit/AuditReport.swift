import Foundation
import HaruspecTrace

/// What one capture-completeness audit found: the declarations it could not read at all, and the
/// deny-listed channels in the ones it could.
///
/// Both halves are blind spots, and they fail the same way on purpose. "I read the source and found a
/// direct `NotificationCenter.default` post" and "I could not find the source" are different facts
/// about the auditor, but the same fact about the verdict: it cannot claim it saw every channel.
public struct AuditReport: Sendable, Equatable {
    /// Declarations whose source could not be located (see `SourceResolution.isResolved`).
    public let unresolved: [SourceResolution]
    /// Deny-listed reaches in the sources that were read, gating and non-gating alike.
    public let findings: [ChannelFinding]

    public init(unresolved: [SourceResolution], findings: [ChannelFinding]) {
        self.unresolved = unresolved
        self.findings = findings
    }

    /// Runs the whole audit: resolves each declaration, then lints what resolved.
    public static func audit(
        origins: some Sequence<TraceOrigin>,
        root: URL,
        rules: [ChannelRule] = ChannelLint.denyList
    ) -> AuditReport {
        let resolutions = SourceResolver(root: root).resolve(origins)
        return AuditReport(
            unresolved: resolutions.filter { !$0.isResolved },
            findings: ChannelLint(root: root, rules: rules).findings(in: resolutions)
        )
    }

    /// Effects leaving through a channel nothing records — the findings that gate.
    public var bypasses: [ChannelFinding] {
        findings.filter { $0.use == .bypass }
    }

    /// Channels supplied as a default at an injection point. Reported, never gating: the harness
    /// overrides the default, so the escape is only real if the spec fails to inject there — which is
    /// a fact about the *run*, not the source, and belongs to the runtime tripwire.
    public var injectableDefaults: [ChannelFinding] {
        findings.filter { $0.use == .injectableDefault }
    }

    /// Nothing left the captured surface, and nothing was unreadable. Only this may leave a green
    /// verdict green.
    public var isClean: Bool {
        unresolved.isEmpty && bypasses.isEmpty
    }

    /// The audit's line on the verdict, as `Qualification.blindSpots` carries it: named channels, each
    /// once, plus the declarations that could not be read. An empty array is a *claim* — audited and
    /// clean — which is why it is only ever produced by an audit that actually ran.
    public var blindSpots: [String] {
        var spots = orderedUnique(bypasses.map(\.channel))
        spots += unresolved.compactMap(\.unresolvedDescription)
        return spots
    }

    /// The findings as a reviewer reads them: what gates first, then what merely wants confirming.
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

/// First occurrence wins, order preserved — findings read in file order, and a channel names itself
/// once however many lines reach it.
func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}
