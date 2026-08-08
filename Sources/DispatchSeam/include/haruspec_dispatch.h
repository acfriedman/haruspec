#ifndef HARUSPEC_DISPATCH_H
#define HARUSPEC_DISPATCH_H

#include <dispatch/dispatch.h>

/// A **preprocessing seam** over GCD's asynchronous dispatch — the one seam type in Feathers'
/// taxonomy (preprocessing / link / object) that the rest of this engine does not use, and the only
/// one that fits `dispatch_async`.
///
/// `dispatch_async` is a C function, not an Objective-C method, so it is unreachable by the object
/// seams (`docs/SEAMS.md`) and by `SeamSwizzle`, which exchanges ObjC method implementations. But the
/// preprocessor reaches anything compiled from source, and reaches it **without editing a single call
/// site** — which is what makes this the smallest safe mechanical change to legacy code that GCD
/// admits.
///
/// ## Enabling point
///
/// The seam is off unless `HARUSPEC_CAPTURE` is defined, and the intended enabling point is a *build
/// setting on a harness configuration*, not a source edit:
///
///     -DHARUSPEC_CAPTURE -include haruspec_dispatch.h
///
/// Legacy sources stay byte-identical, and production cannot reach this code at all. Compared with
/// swizzling, a preprocessing seam is compile-time, scoped to one configuration, visible in the
/// preprocessed output, and structurally incapable of leaking into a release build.
///
/// ## What it buys
///
/// Wrapping the enqueue — rather than intercepting the execution — is what makes three separate
/// problems tractable at once, because the *enqueue site* is the only place all three are known:
///
///  1. **Reachability** — the recorder is a task-local, and a GCD block runs on a thread with no Swift
///     task. Capturing the ambient recorder here and rebinding it inside the block restores capture
///     with true causal inheritance: only work descended from a traced call is captured.
///  2. **Quiescence** — every wrapped enqueue is counted out and counted back in, so "has the work
///     finished?" is an exact question rather than a heuristic about idle queues.
///  3. **Happens-before edges** — the enqueue site knows which event spawned the work. That is the one
///     place the causal edge exists, and it is gone by the time the block runs.
///
/// ## Limits
///
/// It reaches only what is compiled from source: not third-party binary frameworks, not GCD calls
/// inside Apple's own frameworks, and not Swift call sites (`DispatchQueue.async`) — Swift has no
/// preprocessor. In a migration that lines up well: the legacy baseline is Objective-C, and the Swift
/// port uses `Task`, which already inherits task-locals.
///
/// `dispatch_sync` is deliberately **not** wrapped: it runs the block on the calling thread, so the
/// task-local is already in scope and the queue label already resolves. There is nothing to restore.

/// Wraps `block` so it carries the enqueueing context, and registers it as outstanding work.
/// Returns `block` unchanged when no capture is active, so the seam is a strict pass-through.
extern dispatch_block_t haruspec_seam_wrap(dispatch_block_t block);

static inline void haruspec_dispatch_async(dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_async(queue, haruspec_seam_wrap(block));
}

static inline void haruspec_dispatch_barrier_async(dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_barrier_async(queue, haruspec_seam_wrap(block));
}

static inline void haruspec_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    dispatch_after(when, queue, haruspec_seam_wrap(block));
}

static inline void haruspec_dispatch_group_async(dispatch_group_t group,
                                                 dispatch_queue_t queue,
                                                 dispatch_block_t block) {
    dispatch_group_async(group, queue, haruspec_seam_wrap(block));
}

#ifdef HARUSPEC_CAPTURE
#define dispatch_async haruspec_dispatch_async
#define dispatch_barrier_async haruspec_dispatch_barrier_async
#define dispatch_after haruspec_dispatch_after
#define dispatch_group_async haruspec_dispatch_group_async
#endif


#endif
