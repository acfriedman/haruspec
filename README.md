# Haruspec

Prove a change kept the behavior you didn't mean to change.

![Tests](https://github.com/acfriedman/haruspec/actions/workflows/tests.yml/badge.svg)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS-blue)
![License](https://img.shields.io/badge/license-Apache%202.0-green)

Haruspec is a spec-driven differential testing framework for Swift and Objective-C. Your existing
code is the **behavioral oracle**: you declare a **spec** of what the subject does (its operations,
observable effects, and input domains) and Haruspec drives the old and new implementations with the
same generated inputs and diffs their behavior. A change passes when it did exactly what you
declared you **intended**, and nothing else.

> ⚠️ **Haruspec is not omniscient. It is a best-effort oracle.**

## Two shapes

One spec verifies in two shapes:

|  | Campaign | Continuous |
| --- | --- | --- |
| Compares | Two implementations, one build | One implementation, two builds |
| Baseline | The legacy code, run live | A recorded plan of `main`'s behavior |
| The question | Does the port behave like the original? | Did this PR change behavior it didn't declare? |
| Ends when | The port ships and the old code is deleted | Never; it is the standing PR gate |

A **campaign** is a migration in progress, such as Objective-C to Swift or a serial queue to an
actor: the legacy implementation is the baseline and every port is a candidate, verified against
it directly in the same build. The **continuous** shape guards a single implementation across
builds: `main`'s behavior is recorded once as a plan, every PR replays that plan, and the plan is
re-recorded on merge, because merging is the endorsement of the new behavior. The same spec
declaration drives both.

## At a glance

This is the entire authored surface for a small checkout subject, verified in the campaign shape. No mocks, no assertions, no
expected values: the legacy implementation is the expected value.

```swift
let cart = Spec<PromoCart>("promo-cart")
    .system(makeLegacyCart)
    .operations {
        Op("addCoffee") { cart, seams in
            cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
        }
        Op("promo") { $0.applyPromo() }
        Op("checkout") { _ = $0.checkout() }.last()
    }
    .vary { Seam("coffeeQty", .int(1 ... 20)) }

let verdict = await cart.verify(against: makeSwiftPort)
print(verdict.report())
```

A faithful port reads `✅ EQUIVALENT`. A port that truncates where the legacy code rounded loses
one cent, and the verdict says exactly where, shrunk to a minimal counterexample:

```text
❌ DIVERGED  promo-cart
  explored: 385 runs · all 7 orderings × 55 seam variants
  stability: 3/3 identical replays
  coverage: 100% of 4 declared boundaries · domain-swept 0%
  covered: PromoCart — 3 ops · 385 probes
  seams: coffeeQty (2 positions) · boundary edges 8 of 8 scheduled
  blind spots: not audited — capture completeness is unmeasured; effect channels outside the recorded seams may exist
  2 divergence(s):
    ≠ CheckoutCompleted: total: baseline=1798 candidate=1799
    ≠ PromoCart.checkout: value: baseline=1798 candidate=1799
  ↳ failing order: addCoffee → addCoffee → promo → promo → checkout
  ↳ counterexample: coffeeQty=1,1
```

Every verdict, green or red, carries that qualification block: what was explored, how stable it
was, and what the oracle could not see.

## Installation

Add the package and depend on the single `Haruspec` product:

```swift
dependencies: [
    .package(url: "https://github.com/acfriedman/haruspec.git", branch: "main")
],
// in your test target:
.product(name: "Haruspec", package: "haruspec")
```

One `import Haruspec` surfaces the macros, capture runtime, seams, and the Spec DSL.

> **Note:** when building with `xcodebuild`, select the simulator with `-destination`, never
> `-sdk`. Passing `-sdk iphonesimulator` overrides `SDKROOT` for the macro host tool and the
> build fails with "produced malformed response".

## Getting started

**1. Declare a spec.** Name the subject's operations, the effects worth observing, and the input
domains to sweep. Most of it can be derived from the boundary protocol itself:

```swift
Spec<Cart>("cart.objc-to-swift", derivedFrom: DerivedCart.self) {
    Amend("applyPromo").varying("code", over: .oneOf("SAVE10", "save10", "NOPE"))
    Amend("checkout").last()
}
```

**2. Verify.** In the campaign shape, two implementations in one build compare directly:

```swift
let verdict = await spec.verify(against: makeSwiftPort)
```

In the continuous shape, record the current behavior once, then replay the recorded plan against
any later build:

```swift
try await spec.record(to: planURL)  // on main
await spec.verify(replaying: plan)  // on the PR
```

**3. Read the verdict.** `EQUIVALENT` means every probe matched under the declared tolerances and
intent. `DIVERGED` names the first difference and shrinks it. `CANNOT-VERIFY` means the oracle
refuses to claim coverage it does not have. `UNSTABLE` means replays of the same build disagreed,
and the run-to-run delta is the diagnostic. Exit codes carry the verdict, so the same command is
the CI gate.

For a working CI setup (PR replay, sticky comments, record-on-merge), see the
[example migration repo](https://github.com/acfriedman/example-xcode-migration).

## How it works

Haruspec captures a trace of the subject's boundary (method calls, notifications, property
snapshots, seam reads, concurrency domains), canonicalizes it, replays the identical generated
inputs against the candidate, and diffs the two traces under the tolerances and intent you
declared. Structural differences (a moved concurrency domain, a relaxed ordering, a dropped
synchronization edge) gate by default until declared. Where capture is incomplete, the verdict
abstains and says why rather than guessing.

| Verdict | Exit | Meaning |
| --- | --- | --- |
| ✅ EQUIVALENT | 0 | Every probe matched; declared intent was observed and absorbed. |
| ❌ DIVERGED | 3 | Behavior differs; the report names the divergence and a minimal counterexample. |
| ⚠️ CANNOT-VERIFY | 4 | Coverage or capture is insufficient to make a claim; the gap is named. |
| 🌀 UNSTABLE | 5 | Identical replays produced different results; the delta is reported per run. |

## Learn more

- [docs/README.md](docs/README.md): the design docs index
- [docs/SEAMS.md](docs/SEAMS.md): the seam catalog, what can be captured and how
- [docs/LIMITATIONS.md](docs/LIMITATIONS.md): honest edges, what the oracle cannot see
- [docs/ROADMAP.md](docs/ROADMAP.md): where this is going
- [example-xcode-migration](https://github.com/acfriedman/example-xcode-migration): the dogfood
  app, a real Objective-C to Swift migration verified on real PRs

## Requirements

Swift 6.0 (Xcode 16 or later) · macOS 13+ · iOS 16+

## License

Apache License 2.0. See [LICENSE](LICENSE).
