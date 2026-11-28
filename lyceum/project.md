# Explainer project: Haruspec, official videos

The official explainer videos for Haruspec, shipped in the engine repository beside the code they
explain. Read before writing any script. Where this guide and the Lyceum skill disagree, this guide wins.

## Audience

An iOS or macOS engineer meeting Haruspec for the first time: fluent in Swift and Objective-C, used to
XCTest or Swift Testing, never seen this codebase. They want to know what Haruspec does, whether it fits
their code, and how to adopt it. They are not contributors: show the surface they write and the verdicts
they read, not the engine's internals, unless an internal is the only honest way to explain a behavior.

## The set

| Video | Pairs with | What a viewer leaves with |
| --- | --- | --- |
| `overview` | the root `README.md` | what Haruspec is, the two shapes, what a verdict looks like, how to start |
| `specs` | `docs/specs.md` | the one thing you write: stamp a protocol, amend what a signature can't say, check a port |
| `seams` | `docs/seams.md` | what the oracle controls, why an uncontrolled seam reads UNSTABLE, how to inject one |
| `verdicts` | `docs/verdicts.md` | the four verdicts, the qualification block, and declaring the change you meant |

Each concept video and its doc tell the same story; the doc carries the code detail the video skips. A
change to one is a reason to check the other. Every video is about five minutes: roughly 750 spoken words
in 6 to 8 scenes.

## Ground truth

Paths are relative to the root of this repository (`haruspec/`):
- `README.md` and `docs/`: the adopter-facing story.
- `Sources/`: the engine. Where code and prose disagree, the code wins.
- `Tests/`: failing fixtures and divergence fixtures make the best on-screen examples, and real verdict
  output beats invented output.
- `Examples/`: runnable adopter code.
- History: `git log` here. Commit messages carry the why.

`example-xcode-migration/` (a checkout beside this one) is the dogfood app: real specs in
`LegacyAppTests/`, real plans in `HaruspecPlans/`. Cite it only where the engine has no equivalent, since
CI has to clone it to check those sources.

## House rules

- **Only what ships.** No roadmap, no proposals, nothing unbuilt. A gap is stated as a gap, in the
  verdict's own terms (CANNOT-VERIFY, UNSTABLE, an audit finding), never as a promise.
- **Code on screen is real.** It compiles against the current API: take it from the README, `Examples/`
  or `Tests/`. If a snippet is simplified, the visual brief says "simplified".
- **No acronyms or shortenings, ever.** Spell everything out, even where the code shortens it:
  "operation", never "op".
- **"Haruspec":** leave it to the voice, with no `pronounce:` entry. Andrew says it "HA-ruh-spec", but
  every respelling tried sounded worse than the voice's own reading.
- **One look across the set.** Baseline (the code you trust) is blue, candidate (the code you changed) is
  pink. Verdicts keep fixed colours: EQUIVALENT green, DIVERGED red, CANNOT-VERIFY amber, UNSTABLE violet.
  The first video built sets `scenes/shared.tsx`; the others copy it.
- **Docs prose:** the README's house style holds for `docs/` too: no em-dashes.

## Review and delivery

CI makes and refreshes these videos unattended, and nobody reviews them, so every claim must come from
the code at the current commit. Each video tells the story of the one file it explains (`explains:`):
the root `README.md` or a page in `docs/`.

- **Runs:** `.github/workflows/lyceum.yml` runs on a push to `main`, weekly, and by hand. It asks
  `lyceum ci plan` what needs work, an agent revises each video, and `lyceum ship` gates it and
  publishes it to the project's store (Cloudflare R2) at a fixed URL.
- **Embeds:** each file shows its video as a thumbnail, between `lyceum:video` markers that
  `lyceum embed` writes. Never edit those files outside that block.
- **Landing:** changes land as pull requests from `lyceum/refresh-*` branches, queued to merge
  themselves once Andrew approves (`main` needs one approval). The video is public before then.
- **Keys:** CI reads them from Actions secrets. On the Mac, `OPENAI_KEY` and the store's keys live in this
  project's own `.env` (gitignored). Lyceum reads no `.env` above the project.
- **By hand:** a video made or revised here goes through the same gates: `npx lyceum stale --mark
  <video>`, then `npx lyceum ship <video>`. Re-render only a changed scene while working
  (`npm run render -- <video> --scene <id>`, `--draft` for a quick 720p look).
