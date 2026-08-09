import Foundation

// The visual companion to `report()`. `report()` is the terse line-oriented rendering a CI log wants;
// `htmlReport()` is the "open it in a browser and *see* the divergence" page — a single self-contained
// HTML document (inline CSS, no external assets, works over `file://`, light + dark aware).
//
// This file is the ONE source of the page chrome (CSS + skeleton) and the reusable divergence-card body,
// mirroring how `DiffReport.swift` owns `bodyLines()`. `TraceDiff.htmlReport()` and
// `VerificationResult.htmlReport()` build on it here; `SpecVerdict.htmlReport()` (in HaruspecSpec)
// wraps the same body with its counterexample hero — so all three entry points render identically.
//
// HaruspecCore is Foundation-only / dependency-free; this is plain string building with no new deps.

/// The shared HTML chrome: page skeleton, CSS, and the reusable section builders every `htmlReport()`
/// composes. Public so the HaruspecSpec entry point can reuse the same building blocks rather than
/// re-declaring the banner/glyph vocabulary and CSS (the mistake the downstream prototype was forced into).
public enum HTML {
    // MARK: - Page skeleton

    /// Wrap pre-built section strings in the full self-contained document (doctype, head, inline CSS,
    /// `<main>`, footer). This is the only place the skeleton and stylesheet live.
    public static func page(title: String, sections: [String]) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <main>
        \(sections.filter { !$0.isEmpty }.joined(separator: "\n"))
        <footer>
          Behavioral diff by <strong>Haruspec</strong> — a deterministic re-run of the candidate against a
          recorded baseline over the same generated inputs. Any divergence above is a real change in
          observable behavior within the declared tolerances, not a plausibility guess.
          <div class="ts">generated \(timestamp())</div>
        </footer>
        </main>
        </body>
        </html>
        """
    }

    // MARK: - Hero

    /// The verdict banner hero: three-tier banner, colored left border, and `baseline → candidate` chips.
    public static func hero(
        _ verdict: TraceDiff.Verdict,
        title: String,
        baseline: String,
        candidate: String
    ) -> String {
        """
        <div class="hero \(accent(verdict))">
          <div class="verdict">\(banner(verdict))</div>
          <div class="lede">
            <div class="spec">\(esc(title))</div>
            <div class="flow"><span class="chip base">\(esc(baseline))</span><span class="arrow">→</span>\
        <span class="chip cand">\(esc(candidate))</span></div>
          </div>
        </div>
        """
    }

    // MARK: - Stat tiles

    /// A responsive row of stat tiles. Pass tiles built with `tile(...)`.
    public static func statSection(_ tiles: [String]) -> String {
        let kept = tiles.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return "" }
        return "<section class=\"stats\">\(kept.joined())</section>"
    }

    /// One stat tile. `accent` is `"ok"` / `"bad"` / `"warn"` (or `nil` for neutral); `mono` for values
    /// that read better in a monospaced font (e.g. seam values).
    public static func tile(label: String, value: String, accent: String? = nil, mono: Bool = false) -> String {
        let cls = ["tile", accent.map { "t-\($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let vcls = mono ? "tv mono" : "tv"
        return "<div class=\"\(cls)\"><div class=\"tl\">\(esc(label))</div>"
            + "<div class=\"\(vcls)\">\(esc(value))</div></div>"
    }

    // MARK: - Counterexample hero

    /// The headline artifact for a shrunk divergence: the minimal failing seam values + call order, called
    /// out up top. Empty when there is nothing to show (no varied seams and no explored ordering).
    public static func counterexampleSection(seams: [(key: String, value: String)], order: [String]?) -> String {
        let hasSeams = !seams.isEmpty
        let hasOrder = !(order ?? []).isEmpty
        guard hasSeams || hasOrder else { return "" }

        var rows: [String] = []
        if hasSeams {
            let chips = seams.map {
                "<span class=\"kv\"><span class=\"k\">\(esc($0.key))</span><span class=\"eq\">=</span>"
                    + "<span class=\"val\">\(esc($0.value))</span></span>"
            }.joined()
            rows.append("<div class=\"cx-row\"><div class=\"cx-label\">seam values</div>"
                + "<div class=\"cx-chips\">\(chips)</div></div>")
        }
        if let order, !order.isEmpty {
            let chain = order.map { "<span class=\"op\">\(esc($0))</span>" }
                .joined(separator: "<span class=\"seq\">→</span>")
            rows.append("<div class=\"cx-row\"><div class=\"cx-label\">failing order</div>"
                + "<div class=\"cx-chips chain\">\(chain)</div></div>")
        }

        return """
        <section class="counterexample">
          <div class="cx-head"><span class="badge shrunk">shrunk</span> Minimal counterexample</div>
          <div class="cx-note">The smallest input the shrinker could reduce to that still \
        reproduces the divergence.</div>
          \(rows.joined())
        </section>
        """
    }

    // MARK: - Divergence body (the HTML analog of TraceDiff.bodyLines())

    /// One card per `Divergence`: kind glyph/badge, label, baseline/candidate seq chips, a classification
    /// badge, and — for `valueMismatch` — a side-by-side baseline-vs-candidate panel with a numeric Δ.
    public static func divergenceSection(_ divergences: [Divergence]) -> String {
        let intentInPlay = divergences.contains { $0.classification == .intended }
        let cards = divergences.map { card($0, intentInPlay: intentInPlay) }.joined()
        return """
        <section class="divs">
          <h2>\(divergences.count) divergence\(divergences.count == 1 ? "" : "s")</h2>
          \(cards)
        </section>
        """
    }

    /// The clean "matched across everything explored" panel for an EQUIVALENT verdict.
    public static func cleanSection(summary: String, detail: String) -> String {
        """
        <section class="clean">
          <div class="check">✓</div>
          <h2>\(esc(summary))</h2>
          <p>\(esc(detail))</p>
        </section>
        """
    }

    /// The CANNOT-VERIFY abstention panel — the oracle refusing to certify a parity it couldn't isolate.
    public static func abstentionSection(reason: String) -> String {
        """
        <section class="abstain">
          <div class="warn-glyph">⚠️</div>
          <h2>Verification inconclusive — the oracle abstained</h2>
          <p>\(esc(reason)) An EQUIVALENT here would be unsound, so the oracle refuses it. Re-record the
          cassette (or declare the seam) to close the gap.</p>
        </section>
        """
    }

    // MARK: - One divergence, as a card

    private static func card(_ divergence: Divergence, intentInPlay: Bool) -> String {
        let mismatch = divergence.kind == .valueMismatch ? parseValueMismatch(divergence.detail) : nil
        let payload: String = if let mismatch {
            valueDiff(field: mismatch.path, baseline: mismatch.baseline, candidate: mismatch.candidate)
        } else {
            "<div class=\"detail\">\(esc(divergence.detail))</div>"
        }

        return """
        <article class="card \(divergence.kind.cssClass)">
          <header>
            <span class="kind"><span class="glyph">\(divergence.kind.glyph)</span>\(divergence.kind.label)</span>
            <span class="label">\(esc(divergence.label))</span>
            \(classificationBadge(divergence, intentInPlay: intentInPlay))
            \(locationChips(divergence))
          </header>
          \(payload)
        </article>
        """
    }

    /// A baseline-vs-candidate value panel, with a numeric delta when both sides parse as numbers.
    private static func valueDiff(field: String, baseline: String, candidate: String) -> String {
        var delta = ""
        if let baseNumber = Double(baseline), let candidateNumber = Double(candidate) {
            let difference = candidateNumber - baseNumber
            let sign = difference > 0 ? "+" : ""
            let shown = (difference == difference.rounded()) ? String(Int64(difference)) : String(difference)
            delta = "<div class=\"delta\">Δ \(sign)\(shown)</div>"
        }
        return """
        <div class="field">\(esc(field))</div>
        <div class="vs">
          <div class="side base"><div class="tag">baseline</div><div class="v">\(esc(baseline))</div></div>
          <div class="op-eq">≠</div>
          <div class="side cand"><div class="tag">candidate</div><div class="v">\(esc(candidate))</div></div>
        </div>
        \(delta)
        """
    }

    private static func locationChips(_ divergence: Divergence) -> String {
        let baselineChip = divergence.baselineSeq.map { "<span class=\"pos base\">baseline #\($0)</span>" } ?? ""
        let candidateChip = divergence.candidateSeq.map { "<span class=\"pos cand\">candidate #\($0)</span>" } ?? ""
        guard !baselineChip.isEmpty || !candidateChip.isEmpty else { return "" }
        return "<span class=\"loc\">\(baselineChip)\(candidateChip)</span>"
    }

    /// intended (declared feature behavior) / collateral (gating, suspected regression) / advisory —
    /// mirrors the `(intended)` / `(collateral)` / `(advisory)` tags in `bodyLines()`.
    private static func classificationBadge(_ divergence: Divergence, intentInPlay: Bool) -> String {
        if divergence.classification == .intended {
            return "<span class=\"badge intended\">intended</span>"
        }
        if divergence.isAdvisory {
            return "<span class=\"badge advisory\">advisory</span>"
        }
        // Only worth flagging "collateral" when there's declared intent to contrast against.
        return intentInPlay ? "<span class=\"badge collateral\">collateral</span>" : ""
    }

    // MARK: - Detail parsing

    /// `"<path>: baseline=<b> candidate=<c>"` → its three parts, or `nil` if the shape doesn't match
    /// (e.g. array-length mismatches, which fall back to the raw detail line).
    private static func parseValueMismatch(_ detail: String) -> (path: String, baseline: String, candidate: String)? {
        guard let colon = detail.range(of: ": ") else { return nil }
        let path = String(detail[..<colon.lowerBound])
        let rest = detail[colon.upperBound...]
        guard rest.hasPrefix("baseline="), let candMark = rest.range(of: " candidate=") else { return nil }
        let baseline = String(rest[rest.index(rest.startIndex, offsetBy: "baseline=".count) ..< candMark.lowerBound])
        let candidate = String(rest[candMark.upperBound...])
        return (path, baseline, candidate)
    }

    // MARK: - Verdict vocabulary (the single HTML copy of it)

    /// The three-tier banner glyph + label.
    public static func banner(_ verdict: TraceDiff.Verdict) -> String {
        switch verdict {
        case .equivalent: "✅ EQUIVALENT"
        case .diverged: "❌ DIVERGED"
        case .cannotVerify: "⚠️ CANNOT-VERIFY"
        }
    }

    /// The short human verdict for a stat tile.
    public static func shortVerdict(_ verdict: TraceDiff.Verdict) -> String {
        switch verdict {
        case .equivalent: "Equivalent"
        case .diverged: "Diverged"
        case .cannotVerify: "Cannot verify"
        }
    }

    /// The CSS accent class (`ok` / `bad` / `warn`) for a verdict.
    public static func accent(_ verdict: TraceDiff.Verdict) -> String {
        switch verdict {
        case .equivalent: "ok"
        case .diverged: "bad"
        case .cannotVerify: "warn"
        }
    }

    // MARK: - Small utilities

    public static func esc(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    // MARK: - Styling (the single stylesheet all three entry points share)

    public static let css = """
    :root {
      --bg:#f6f7f9; --panel:#ffffff; --ink:#1d2430; --muted:#6b7684; --line:#e5e8ec;
      --ok:#1a7f47; --ok-bg:#e7f6ed; --bad:#c22f3d; --bad-bg:#fdecec; --warn:#9a6a00; --warn-bg:#fbf1d9;
      --base:#5b6472; --cand:#2b6cb0;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg:#0f1319; --panel:#171c24; --ink:#e7ebf0; --muted:#96a0ae; --line:#252c37;
        --ok:#5bd68d; --ok-bg:#12321f; --bad:#ff7b86; --bad-bg:#38181b; --warn:#f2c65a; --warn-bg:#3a2f10;
        --base:#9aa4b2; --cand:#6fb1e6;
      }
    }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--bg); color:var(--ink);
      font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
    main { max-width:820px; margin:0 auto; padding:32px 20px 64px; }
    .mono { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
    h2 { font-size:15px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 14px; }

    .hero { border:1px solid var(--line); border-radius:16px; padding:22px 24px; background:var(--panel);
      display:flex; align-items:center; gap:22px; border-left-width:6px; }
    .hero.ok { border-left-color:var(--ok); } .hero.bad { border-left-color:var(--bad); } \
    .hero.warn { border-left-color:var(--warn); }
    .hero .verdict { font-size:26px; font-weight:700; white-space:nowrap; }
    .lede { margin-left:auto; text-align:right; }
    .spec { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; color:var(--muted); \
    font-size:13px; margin-bottom:8px; }
    .flow { display:flex; align-items:center; gap:10px; justify-content:flex-end; }
    .flow .arrow { color:var(--muted); }
    .chip { padding:4px 10px; border-radius:999px; font-size:13px; font-weight:600; border:1px solid var(--line); }
    .chip.base { color:var(--base); } .chip.cand { color:var(--cand); border-color:var(--cand); }

    .stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin:18px 0; }
    .tile { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:14px 16px; }
    .tile .tl { font-size:12px; text-transform:uppercase; letter-spacing:.05em; color:var(--muted); margin-bottom:6px; }
    .tile .tv { font-size:20px; font-weight:700; }
    .tile .tv.mono { font-size:15px; }
    .t-ok .tv { color:var(--ok); } .t-bad .tv { color:var(--bad); } .t-warn .tv { color:var(--warn); }

    .counterexample { background:var(--bad-bg); border:1px solid color-mix(in srgb,var(--bad) 30%,transparent);
      border-radius:14px; padding:18px 20px; margin:18px 0 24px; }
    .cx-head { font-weight:700; font-size:16px; margin-bottom:4px; }
    .badge { font-size:11px; font-weight:700; text-transform:uppercase; letter-spacing:.06em; padding:2px 8px;
      border-radius:6px; margin-right:8px; vertical-align:middle; }
    .badge.shrunk { background:var(--bad); color:#fff; }
    .badge.intended { background:var(--ok-bg); color:var(--ok); }
    .badge.collateral { background:var(--bad-bg); color:var(--bad); }
    .badge.advisory { background:var(--warn-bg); color:var(--warn); }
    .cx-note { color:var(--muted); font-size:13px; margin-bottom:14px; }
    .cx-row { display:flex; gap:14px; align-items:baseline; padding:6px 0; }
    .cx-label { width:100px; flex:none; font-size:12px; text-transform:uppercase; letter-spacing:.05em; \
    color:var(--muted); }
    .cx-chips { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
    .kv { display:inline-flex; align-items:center; background:var(--panel); border:1px solid var(--line);
      border-radius:8px; padding:4px 10px; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; \
    font-size:13px; }
    .kv .k { color:var(--muted); } .kv .eq { color:var(--muted); margin:0 3px; } .kv .val { font-weight:700; }
    .op { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:4px 10px;
      font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:13px; }
    .chain .seq { color:var(--muted); margin:0 2px; }

    .card { background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:16px 18px;
      margin-bottom:12px; border-left-width:5px; }
    .card.k-value { border-left-color:var(--warn); } .card.k-missing { border-left-color:var(--bad); }
    .card.k-unexpected { border-left-color:#8b5cf6; } .card.k-reordered { border-left-color:var(--cand); }
    .card.k-timing { border-left-color:#0d9488; }
    .card header { display:flex; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:12px; }
    .kind { font-size:12px; font-weight:700; text-transform:uppercase; letter-spacing:.04em; color:var(--muted);
      display:inline-flex; align-items:center; gap:6px; }
    .kind .glyph { font-size:15px; }
    .label { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-weight:700; font-size:15px; }
    .loc { margin-left:auto; display:flex; gap:6px; }
    .pos { font-size:12px; padding:2px 8px; border-radius:6px; border:1px solid var(--line); color:var(--muted); }
    .pos.cand { color:var(--cand); border-color:color-mix(in srgb,var(--cand) 40%,transparent); }

    .field { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:13px; \
    color:var(--muted); margin-bottom:10px; }
    .vs { display:flex; align-items:stretch; gap:12px; }
    .side { flex:1; border:1px solid var(--line); border-radius:10px; padding:10px 14px; }
    .side .tag { font-size:11px; text-transform:uppercase; letter-spacing:.05em; color:var(--muted); \
    margin-bottom:6px; }
    .side .v { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:20px; font-weight:700; }
    .side.base .v { color:var(--base); }
    .side.cand { background:var(--bad-bg); border-color:color-mix(in srgb,var(--bad) 35%,transparent); }
    .side.cand .v { color:var(--bad); }
    .op-eq { align-self:center; color:var(--bad); font-size:20px; font-weight:700; }
    .delta { margin-top:10px; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:13px;
      color:var(--bad); font-weight:700; }
    .detail { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:13px; color:var(--ink); }

    .clean { background:var(--ok-bg); border:1px solid color-mix(in srgb,var(--ok) 30%,transparent);
      border-radius:14px; padding:28px; text-align:center; }
    .clean .check { font-size:44px; color:var(--ok); line-height:1; margin-bottom:10px; }
    .clean h2 { color:var(--ok); }
    .clean p { color:var(--muted); max-width:52ch; margin:8px auto 0; }

    .abstain { background:var(--warn-bg); border:1px solid color-mix(in srgb,var(--warn) 30%,transparent);
      border-radius:14px; padding:28px; text-align:center; }
    .abstain .warn-glyph { font-size:40px; line-height:1; margin-bottom:10px; }
    .abstain h2 { color:var(--warn); }
    .abstain p { color:var(--muted); max-width:56ch; margin:8px auto 0; }

    .coverage { background:var(--panel); border:1px solid var(--line); border-radius:14px; \
    padding:18px 20px; margin:18px 0; }
    .coverage h2 { margin-bottom:12px; }
    .cov-gap { color:var(--warn); font-size:13px; margin-top:8px; }
    .cov-gap::before { content:"gap · "; color:var(--muted); }

    footer { margin-top:28px; color:var(--muted); font-size:12px; line-height:1.6; \
    border-top:1px solid var(--line); padding-top:16px; }
    footer .ts { margin-top:6px; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }

    @media (max-width:560px) {
      .hero { flex-direction:column; align-items:flex-start; } .lede { margin-left:0; text-align:left; } \
    .flow { justify-content:flex-start; }
      .vs { flex-direction:column; } .op-eq { transform:rotate(90deg); }
    }
    """
}

// MARK: - Entry points

public extension TraceDiff {
    /// A self-contained, themeable HTML rendering of this diff — the visual companion to `report()`.
    /// Leads with the verdict hero and a small stat row, then one card per divergence (or a clean panel).
    func htmlReport() -> String {
        HTML.page(title: "Haruspec · \(candidateName)", sections: [
            HTML.hero(verdict, title: candidateName, baseline: baselineName, candidate: candidateName),
            HTML.statSection(statTiles),
            body
        ])
    }

    /// The verdict + divergence-count tiles shared by the diff and verification pages.
    internal var statTiles: [String] {
        [HTML.tile(label: "Verdict", value: HTML.shortVerdict(verdict), accent: HTML.accent(verdict)),
         HTML.tile(label: "Divergences", value: "\(divergences.count)", accent: divergences.isEmpty ? "ok" : "bad")]
    }

    /// The divergence cards, or the clean/abstain panel — the visual analog of `bodyLines()`, reused by
    /// every full-page entry point.
    internal var body: String {
        if !divergences.isEmpty {
            return HTML.divergenceSection(divergences)
        }
        switch verdict {
        case .cannotVerify:
            return HTML.abstentionSection(reason: "The oracle could not faithfully isolate this change.")
        default:
            return HTML.cleanSection(
                summary: "Behavior matched",
                detail: "Every compared event produced a byte-for-byte identical behavior trace "
                    + "(within declared tolerances). No divergences."
            )
        }
    }
}

public extension VerificationResult {
    /// A self-contained, themeable HTML rendering of the replay-driven verification — the diff page plus a
    /// coverage panel, since an EQUIVALENT verdict is only as strong as the surface it was measured over.
    func htmlReport() -> String {
        var tiles = diff.statTiles
        if let fraction = coverage.fraction {
            tiles.append(
                HTML.tile(
                    label: "Coverage",
                    value: "\(coverage.exercised.count)/\(coverage.declared.count) (\(percent(fraction)))",
                    accent: coverage.trustsEquivalent ? "ok" : "warn"
                )
            )
        }

        var sections = [
            HTML.hero(verdict, title: diff.candidateName, baseline: diff.baselineName, candidate: diff.candidateName),
            HTML.statSection(tiles),
            coverageSection
        ]
        if verdict == .cannotVerify {
            sections.append(HTML.abstentionSection(reason: htmlAbstentionReason))
        } else {
            sections.append(diff.body)
        }
        return HTML.page(title: "Haruspec · \(diff.candidateName)", sections: sections)
    }

    private var coverageSection: String {
        var rows: [String] = []
        if let fraction = coverage.fraction {
            rows.append("<div>\(coverage.exercised.count)/\(coverage.declared.count) "
                + "declared seams exercised (\(percent(fraction)))</div>")
            if let domain = coverage.domainFraction, !coverage.domainExercised.isEmpty {
                rows.append("<div>\(coverage.domainExercised.count)/\(coverage.declared.count) seam(s) "
                    + "swept over a value domain (\(percent(domain)))</div>")
            }
        } else {
            rows.append("<div>coverage unknown — no declared seam surface to measure against</div>")
        }
        let missed = coverage.unrecordedReach
        if !missed.isEmpty {
            let list = missed.map { HTML.esc("\($0.boundary)#\($0.ordinal ?? 0)") }.joined(separator: ", ")
            rows.append("<div class=\"cov-gap\">reached \(missed.count) unrecorded boundary(ies), "
                + "fell back to live — \(list)</div>")
        }
        let unexercised = coverage.gaps.filter { $0.reason == .unexercised }
        if !unexercised.isEmpty {
            let list = unexercised.map { HTML.esc($0.boundary) }.joined(separator: ", ")
            rows.append("<div class=\"cov-gap\">\(unexercised.count) declared boundary(ies) "
                + "never reached this run — \(list)</div>")
        }
        return "<section class=\"coverage\"><h2>Coverage</h2>\(rows.joined())</section>"
    }

    private var htmlAbstentionReason: String {
        coverage.unrecordedReach.isEmpty
            ? "Verification was inconclusive because there is no declared seam surface to certify equivalence over."
            : "Verification was inconclusive because the change crossed a boundary the recording "
            + "didn't cover, so the environment wasn't held identical."
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Writing the report to disk

/// A verdict carrier that can render itself to a self-contained HTML report page. Conformed by every
/// carrier that has an `htmlReport()` — `TraceDiff`, `VerificationResult`, and (in HaruspecSpec)
/// `SpecVerdict` — so the persistence step below is written once instead of hand-rolled at each call
/// site. Rendering is the package's job (`htmlReport()`); *writing the string to a file* used to be the
/// one bit every consumer (the CLI, the dogfood app) re-implemented with `FileManager` — this folds it in.
public protocol HTMLReporting {
    /// A self-contained, themeable HTML rendering of this verdict — the visual companion to `report()`.
    func htmlReport() -> String
}

public extension HTMLReporting {
    /// Render and write the report to an exact URL, throwing on failure. For callers that own the
    /// destination (e.g. the CLI's `--html <path>`).
    func writeHTMLReport(to url: URL) throws {
        try htmlReport().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Render and write the report to `directory/<name>.html`, creating the directory if needed. Defaults
    /// to a `HaruspecReports` folder under the system temp dir. Returns the written file's URL, or `nil` on
    /// failure — the "just give me a path I can open" convenience for tests and dev tooling.
    @discardableResult
    func writeHTMLReport(named name: String, in directory: URL? = nil) -> URL? {
        let dir = directory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("HaruspecReports", isDirectory: true)
        let url = dir.appendingPathComponent("\(name).html")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeHTMLReport(to: url)
            return url
        } catch {
            return nil
        }
    }
}

extension TraceDiff: HTMLReporting {}
extension VerificationResult: HTMLReporting {}

/// Per-kind presentation, kept on the kind rather than inside the report builder — three parallel
/// switches over one enum belong next to it, and the builder was over its size budget carrying them.
private extension Divergence.Kind {
    var glyph: String {
        switch self {
        case .missingEvent: "−"
        case .unexpectedEvent: "+"
        case .reordered: "↔"
        case .domainMigration: "⇄"
        case .orderingRelaxed: "⤳"
        case .valueMismatch: "≠"
        case .timingRegression: "⏱"
        }
    }

    var label: String {
        switch self {
        case .missingEvent: "missing event"
        case .unexpectedEvent: "unexpected event"
        case .reordered: "reordered"
        case .domainMigration: "domain migration"
        case .orderingRelaxed: "ordering relaxed"
        case .valueMismatch: "value mismatch"
        case .timingRegression: "timing regression"
        }
    }

    var cssClass: String {
        switch self {
        case .missingEvent: "k-missing"
        case .unexpectedEvent: "k-unexpected"
        case .reordered, .domainMigration, .orderingRelaxed: "k-reordered"
        case .valueMismatch: "k-value"
        case .timingRegression: "k-timing"
        }
    }
}
