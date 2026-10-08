// The `haruspec help` text: every subcommand, its flags, and its exit codes. Kept beside `main.swift`
// rather than in it so the dispatch stays readable at a glance.

/// The help text printed by `haruspec help` and after every usage error.
let usage = """
haruspec — the behavioral-oracle engine

USAGE:
  haruspec diff <baseline.json> <candidate.json> [--comparison <comparison.json>] [--intent <spec.json>]\
 [--agent] [--json] [--html <path>]
      Diff two captured traces. Exits 3 if they diverge.
      --intent <spec.json>  extension mode: absorb declared changes, gate only on collateral ones.
      --agent               append a relay guide telling a consuming agent how to report the verdict.
      --html <path>         also write a self-contained visual HTML report to <path>.

  haruspec init [--root <dir>]
      Opt a repository in to the local check: writes .haruspec/bin/haruspec (the launcher, which
      runs the CLI at exactly the engine version the project uses) and, when missing,
      .haruspec/config.json detected from the Xcode project. Commit both.

  haruspec check [--base <branch>] [--spec <a,b>] [--intent <file>] [--root <dir>] [--all]
      The local continuous check (opt-in: needs .haruspec/config.json), for the slice of code your
      change touches. Records the merge base's behavior once per base commit into .haruspec/cache/,
      noting the files each spec's recording executed; replays only the specs whose files changed
      (uncommitted changes included), running only each spec's own suite, under the branch's intent
      doc; exits with the worst verdict code. Each red spec ends with the `haruspec intent save`
      command that would declare its divergences.
      --all                 replay every spec, including those the change does not touch.
      --base <branch>       compare against this branch's merge base (default: config "base", then main).
      --spec <a,b>          check only these specs (default: config "specs", then every declared spec).
      --intent <file>       the intent doc to check under (default: .haruspec/intent/<branch>.md).

  haruspec intent save <spec> <declaration>... [--replace] [--intent <file>]
  haruspec intent remove <spec> [--intent <file>]
      Edit the branch's intent doc (.haruspec/intent/<branch>.md): ```haruspec-intent blocks in the
      PR-description format, so the file can be pasted into a PR as-is. save adds the declarations
      (--replace: replaces the spec's lines), validating each with the gate's grammar; the next
      check writes its verdict under them as evidence. Commit the doc or gitignore it — the team's call.

  haruspec demo [--out <dir>] [--html]
      Capture the built-in checkout spec (baseline / refactor / regression / feature),
      write the traces, and print the verdicts — including parity vs. extension mode. Great first run.
      --html                also write a visual HTML report per verdict into <dir>.

  haruspec canonicalize <trace.json> [--comparison <comparison.json>] [--out <file.json>]
      Emit the canonical, redacted form of a trace.

  haruspec report <result.json>... [--markdown] [--html <path>] [--agent] [--changed <file> --root <dir>]
      Render spec verdict artifacts (the result.json a verify(replaying:) run writes) and exit
      with the worst verdict code — the CI gate reads THIS exit code, not the test runner's.
      With several artifacts, or --changed, the run renders as one continuous report: verdicts the
      diff touches in full, a red verdict the diff does NOT touch leads the report, untouched
      greens collapse to a line each. An unreadable artifact renders as an infrastructure failure
      (exit 1) instead of hiding the rest.
      --markdown            GitHub-flavored markdown (PR comment / job summary) instead of text.
      --html <path>         also write the self-contained visual report to <path> (single artifact only).
      --agent               append the relay guide telling a consuming agent how to report the verdict
                            (single artifact only).
      --changed <file>      newline-separated repo-relative paths (git diff --name-only) to scope by.
      --root <dir>          the checkout the verdicts' declared origins resolve against.

  haruspec audit --root <dir> [--verdict <result.json>] [--covering <Sym,Sym>]
      Capture-completeness audit: resolve the covered declarations to source under <dir>, then read
      that source for effect channels the capture cannot see (NotificationCenter.default, Timer,
      Combine, KVO, dispatch). Exits 4 if any channel is found OR any declaration's source
      cannot be located — both mean the verdict cannot claim it saw everything.
      --verdict <result.json>  audit exactly what that verdict covered (its recorded origins).
      --covering <Sym,Sym>     audit these declarations by name (Obj-C classes, Swift types).

  haruspec mcp
      Serve the engine as MCP tools over stdio (verify_behavioral_parity, canonicalize_trace),
      so agents (Claude Code, Cursor, …) can gate changes on behavioral proof. Register with:
      { "command": "haruspec", "args": ["mcp"] }

  haruspec intent (--body <file> | --bodies <dir>) --out <dir>
      Resolve a PR description's declared intent. Extracts every ```haruspec-intent <spec> fenced
      block from <file>, parses the declarations (the DSL's own spellings — Changes("Search.query"),
      Changes("Receipt", field: "discountCents").increases(), Moves("L", from: .main, to: .ambient),
      …; a chained modifier narrows what the declaration absorbs), and writes one <spec>.intent.json per block into
      <dir> for the replay to pick up via HARUSPEC_INTENT_PATH. A body with no blocks writes
      nothing: parity mode. Exits 1 on an unparseable block — a declaration nobody can read must
      fail loudly, never silently become parity.
      --bodies <dir>        the record-on-merge form: one file per merged PR body, blocks unioned
                            per spec across bodies (each body still parses alone).

  haruspec stamp --plan <plan.json[.gz]> --recorded-at <sha> --coverage <file>
      Write the record-on-merge provenance stamp into a plan artifact, in place: the commit the
      recording built, and the newline-separated repo-relative source files the recording executed
      (its discovered dependency list). Refuses an empty coverage list — a recording that executed
      nothing is a broken extraction, not a dependency-free plan.

  haruspec sweep --plans <dir> --root <repo> [--census <dir>] [--test-sources <prefix>]
      The record-on-merge reconciliation: for each committed plan, diff the repo since its stamped
      recordedAt and intersect with its covered sources. Prints JSON (stdout) partitioning specs
      into stale / births / orphaned / unreadable / fresh, with reasons; human lines on stderr.
      Unstamped or unanswerable plans are stale fail-safe — freshness is a proof, never a default.
      --census <dir>        a census run's <spec>.census.json markers; enables births/orphaned.
      --test-sources <p>    repo-relative prefix of spec declarations; without --census, a changed
                            file under it that no plan covers sets censusAdvised.
"""
