# Haruspec

<!-- Tagline: one sentence, plain words. What it does, not how.
     Working slot: "Prove a change kept the behavior you didn't mean to change." -->

<!-- Badges: Swift version · platforms · license · CI. Add as each becomes real
     (no LICENSE file or engine-repo CI workflow exists yet). -->

Haruspec is a spec-driven differential testing framework for Swift and Objective-C. Your existing
code is the **behavioral oracle**: you declare a **spec** of what the subject does (its operations,
observable effects, and input domains) and Haruspec drives the old and new implementations with the
same generated inputs and diffs their behavior. A change passes when it did exactly what you
declared you **intended**, and nothing else.

> ⚠️ **Haruspec is not omniscient. It is a best-effort oracle.**

## At a glance

<!-- The hook — show, don't tell. One minimal Spec declaration (~10 lines) and the verdict it
     produces, including the qualification block. One green run and one caught one-cent
     regression beats any paragraph. -->

## Installation

<!-- SPM snippet: package dependency + the single `Haruspec` product / `import Haruspec`.
     One footnote-level warning: build with -destination, never -sdk (macro host tool). -->

## Getting started

<!-- Three numbered steps, each a few lines of code, nothing more:
     1. Declare a spec — .system / .operations / .observe / .vary
     2. Verify — verify(against:) for two implementations in one build (parity),
        or record() / verify(replaying:) across builds (the PR gate)
     3. Read the verdict — EQUIVALENT / DIVERGED / CANNOT-VERIFY / UNSTABLE, and what
        each means for the gate (exit codes)
     End with a pointer: "wired into CI" → the example repo's working setup. -->

## How it works

<!-- One short paragraph: capture → canonicalize → replay identical inputs → diff under
     declared tolerances; abstains rather than guess. A 4-row table of the verdict tiers is
     the only structure this section needs. Everything deeper links out. -->

## Learn more

<!-- One line each — the reading path, not a sitemap:
     - docs/README.md      — design docs index
     - docs/SEAMS.md       — the seam catalog: what can be captured, and how
     - docs/LIMITATIONS.md — honest edges; what the oracle cannot see
     - docs/ROADMAP.md     — where this is going
     - example-xcode-migration — the dogfood app: a real migration verified on real PRs -->

## Requirements

<!-- Swift/Xcode/platform minimums, one line. -->

## License

<!-- Add when a LICENSE lands; say "TBD" until then rather than implying one. -->
