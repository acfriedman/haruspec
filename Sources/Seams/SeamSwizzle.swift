import Foundation
import ObjectiveC

/// Method swizzling, retained for **exactly two jobs** — not as a runtime observation mechanism.
///
/// The canonical path is the *injectability precondition*: ask for the smallest behavior-preserving
/// refactor that makes a boundary injectable (a settable-`.shared` behind a protocol — one file, all call
/// sites untouched), then observe it through clean DI with no interception. See `SEAMS.md`. Swizzling
/// survives only where that leaves a residue:
///
/// 1. **The one-shot bootstrap.** Making a singleton injectable is itself an unverified refactor, and
///    there's no seam yet to verify it with. So swizzle the *pre-refactor* singleton once to capture a
///    golden, apply the injectability refactor, and diff → EQUIVALENT certifies the seam. Then the swizzle
///    is thrown away and every downstream verification rides the DI seam. Magic quarantined to verifying
///    its own retirement, run once on the seam-introduction diff — never continuously.
/// 2. **The no-source-binary holdout.** A third-party *binary* framework with no source can't be made
///    injectable at all — the irreducible case where a one-time swizzle/interpose is the only reach.
///
/// It swaps a method's implementation with a paired one (the classic swizzle idiom). Only `@objc dynamic`
/// (or ObjC) methods are swizzlable; pure-Swift static/vtable dispatch is not. Install under `#if DEBUG` /
/// harness setup so production is untouched; when no cassette is bound the paired method passes through.
public enum SeamSwizzle {
    /// Exchange two instance-method implementations on `cls`. Afterwards, invoking `original` runs
    /// `replacement`'s body and vice-versa — so `replacement` reaches the original by calling *itself*.
    /// Returns `false` if either selector isn't found (e.g. the method isn't `@objc`).
    @discardableResult
    public static func exchange(_ cls: AnyClass, _ original: Selector, with replacement: Selector) -> Bool {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else { return false }
        method_exchangeImplementations(originalMethod, replacementMethod)
        return true
    }
}
