#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LegacyCatalogCompletion)(NSArray<NSString *> *products);

/// A legacy-style Objective-C network client in the **callback-pyramid** shape: hop to a background
/// queue, do the work, hop back to the main queue to deliver. This is the exact shape of the dogfood
/// app's `APIClient` (`LegacyApp/Features/Catalog/APIClient.m`), reproduced here so the capture gaps it
/// exposes are demonstrable in a plain `swift test` run rather than only on a simulator.
///
/// It exists to fail. Two distinct gaps live in this file:
///
/// 1. **Reachability** — the block passed to `dispatch_async` runs on a thread with no Swift task, so
///    the recorder (a `@TaskLocal`) cannot be found from inside it. Work happens; no events are
///    recorded. GCD predates Swift concurrency and carries no task context.
/// 2. **Quiescence** — `-warmCache` enqueues work and returns immediately. Nothing the harness can
///    await tells it when that work finished, so a trace snapshot taken at the end of a spec races it.
@interface LegacyCatalogClient : NSObject

/// A `dispatch_once` singleton — the common legacy shape.
+ (instancetype)sharedClient;

/// Background hop → work → main-queue hop to deliver. `notifier` is invoked **on the background
/// queue**, before the completion, standing in for the traced work a real client does off-thread.
- (void)fetchProductsWithNotifier:(nullable dispatch_block_t)notifier
                       completion:(LegacyCatalogCompletion)completion;

/// Fire-and-forget: enqueues work and returns immediately. There is no handle, no completion and
/// nothing to await — the caller cannot know when `cacheWarmedHandler` will run, or whether it already
/// has. The quiescence problem in one method.
- (void)warmCache;

/// Invoked from whichever queue the warm-cache work landed on.
@property (nonatomic, copy, nullable) dispatch_block_t cacheWarmedHandler;

@end

NS_ASSUME_NONNULL_END
