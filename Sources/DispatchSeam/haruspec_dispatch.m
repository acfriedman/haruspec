#import "haruspec_dispatch.h"

// Implemented in Swift (`Sources/Trace/DispatchSeam.swift`). Declared by hand rather than imported:
// this target is plain Objective-C so that legacy sources can include it with no Swift interop, and
// the symbols resolve at link time against whatever binary also links HaruspecTrace.
//
// The context is an opaque retained handle rather than a block, deliberately — passing blocks *into*
// Swift bridges cleanly, returning them does not, and the ownership mismatch is exactly the kind of
// bug a seam like this must not have.
extern void *_Nullable haruspec_context_acquire(void);
extern void haruspec_context_run(void *context, dispatch_block_t block);
extern void haruspec_context_release(void *context);

dispatch_block_t haruspec_seam_wrap(dispatch_block_t block) {
    void *context = haruspec_context_acquire();
    if (context == NULL) {
        return block; // no capture active — strict pass-through, nothing observes this
    }
    return ^{
        haruspec_context_run(context, block);
        haruspec_context_release(context);
    };
}
