import Foundation

// The static half of the capture-completeness audit: read the sources a verdict's declarations
// resolved to, and find effect channels that leave the captured surface. A subject that posts
// through `NotificationCenter.default`, fires a `Timer`, or publishes through Combine produces
// effects the trace never sees — and reads EQUIVALENT. That is the one failure that costs trust
// permanently: not a divergence judged wrongly, but a channel never seen at all.
//
// Deliberately grep-grade. A deny-list is enumerable, never exhaustive, and this shrinks the silent
// surface rather than zeroing it — the runtime tripwire is the other half, and the disclaimer stays
// either way. Over-reporting is the safe direction here: a false finding is declared away in one
// reviewable line, a missed one ships as a silent green.

/// One deny-listed way out of the captured surface.
public struct ChannelRule: Sendable, Equatable {
    /// How the finding is named on a verdict — the channel, not the spelling that matched.
    public let channel: String
    /// Source spellings that reach it, in either language.
    public let spellings: [String]
    /// Whether this spelling names an *object* whose position decides the finding.
    ///
    /// `[NSNotificationCenter defaultCenter]` handed to an initializer is a default being supplied at
    /// an injection point — the harness overrides it, so nothing escapes. The same expression as the
    /// receiver of a message send is an effect leaving through a channel nothing is recording. Legacy
    /// Obj-C is full of the first (`- (instancetype)init { return [self initWithCenter:[… defaultCenter]]; }`),
    /// and gating on it would bury the second. Rules naming a *construct* — `import Combine`, a timer,
    /// a delayed dispatch — have no such reading and are always a reach.
    public let positionDecides: Bool

    public init(channel: String, spellings: [String], positionDecides: Bool = false) {
        self.channel = channel
        self.spellings = spellings
        self.positionDecides = positionDecides
    }
}

/// What a matched line does with the channel — and therefore whether it gates.
public enum ChannelUse: String, Sendable, Equatable {
    /// An effect leaving through an unrecorded channel. Gates.
    case bypass
    /// The channel supplied as a default at an injection point the harness can override. Reported so
    /// a reviewer can confirm the spec *does* inject there, but it does not gate on its own.
    case injectableDefault
}

/// One deny-listed reach, at the line that reaches it.
public struct ChannelFinding: Sendable, Equatable {
    public let channel: String
    public let use: ChannelUse
    public let file: String
    public let line: Int
    /// The source line itself, trimmed — a finding a reviewer can judge without opening the file.
    public let text: String

    public init(channel: String, use: ChannelUse = .bypass, file: String, line: Int, text: String) {
        self.channel = channel
        self.use = use
        self.file = file
        self.line = line
        self.text = text
    }

    public var description: String {
        "\(file):\(line) — \(channel): \(text)"
    }
}

public struct ChannelLint: Sendable {
    /// The channels a captured subject must not reach directly. Each is a boundary Haruspec observes
    /// by *injection* (a notification center, a collaborator) or reaches with a seam (dispatch) — so a
    /// direct use is precisely a use that routes around the recorder.
    public static let denyList: [ChannelRule] = [
        ChannelRule(
            channel: "NotificationCenter.default",
            spellings: ["[NSNotificationCenter defaultCenter]", "NotificationCenter.default"],
            positionDecides: true
        ),
        ChannelRule(
            channel: "Timer / RunLoop",
            spellings: ["NSTimer", "Timer.scheduledTimer", "Timer.publish", "performSelector:withObject:afterDelay:"]
        ),
        ChannelRule(
            channel: "Combine",
            spellings: ["import Combine", "PassthroughSubject", "CurrentValueSubject", ".sink("]
        ),
        ChannelRule(
            channel: "KVO",
            spellings: ["addObserver:forKeyPath:", "addObserver(forKeyPath:", "observe(\\."]
        ),
        ChannelRule(
            channel: "delayed dispatch",
            spellings: ["dispatch_after", "asyncAfter("]
        )
    ]

    private let root: URL
    private let rules: [ChannelRule]

    public init(root: URL, rules: [ChannelRule] = ChannelLint.denyList) {
        self.root = root
        self.rules = rules
    }

    /// Every deny-listed reach in the resolved sources, file order preserved. Unresolved declarations
    /// contribute nothing here on purpose — they are a *separate* and more serious finding (see
    /// `AuditReport`), not an absence of one.
    public func findings(in resolutions: some Sequence<SourceResolution>) -> [ChannelFinding] {
        var findings: [ChannelFinding] = []
        var audited: Set<String> = []
        for file in resolutions.flatMap(\.files) where audited.insert(file).inserted {
            findings += self.findings(inFile: file)
        }
        return findings
    }

    /// Where the channel sits in the line decides what it is.
    ///
    /// Receiver of a message (`[[… defaultCenter] post…]`, `NotificationCenter.default.post`) is an
    /// effect going out. Passed as an argument — after an Obj-C selector keyword, a comma, an open
    /// paren, or as a default inside a parameter list — is the injection point doing its job. Anything
    /// else gates, including `let center = NotificationCenter.default`: a global cached into a field is
    /// the temporal hole injection is *supposed* to close, not an instance of it being closed.
    static func use(of spelling: String, in line: String) -> ChannelUse {
        guard let match = line.range(of: spelling) else { return .bypass }
        let after = line[match.upperBound...].drop { $0 == " " || $0 == "\t" }.first
        if let after, after.isLetter || after == "." {
            return .bypass
        }
        let prefix = line[..<match.lowerBound]
        guard let before = prefix.last(where: { $0 != " " && $0 != "\t" }) else { return .bypass }
        if before == ":" || before == "," || before == "(" {
            return .injectableDefault
        }
        // A Swift defaulted parameter (`center: NotificationCenter = .default`) is an argument too —
        // the `=` only means assignment when it is not inside the parameter list.
        let open = prefix.filter { $0 == "(" }.count - prefix.filter { $0 == ")" }.count
        return before == "=" && open > 0 ? .injectableDefault : .bypass
    }

    private func findings(inFile file: String) -> [ChannelFinding] {
        guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else {
            return []
        }
        var findings: [ChannelFinding] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A mention in a comment is documentation, not a reach.
            guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("/*") else { continue }
            for rule in rules {
                guard let spelling = rule.spellings.first(where: line.contains) else { continue }
                findings.append(ChannelFinding(
                    channel: rule.channel,
                    use: rule.positionDecides ? ChannelLint.use(of: spelling, in: line) : .bypass,
                    file: file,
                    line: offset + 1,
                    text: line
                ))
            }
        }
        return findings
    }
}
