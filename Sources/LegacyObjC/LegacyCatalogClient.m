#import "LegacyCatalogClient.h"

// Stands in for the build setting a real adopter uses (`-include haruspec_dispatch.h` on a harness
// configuration). SwiftPM has no prefix-header knob, so the fixture includes it directly.
#import "haruspec_dispatch.h"

@implementation LegacyCatalogClient

+ (instancetype)sharedClient {
    static LegacyCatalogClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LegacyCatalogClient alloc] init];
    });
    return instance;
}

- (void)fetchProductsWithNotifier:(dispatch_block_t)notifier
                       completion:(LegacyCatalogCompletion)completion {
    dispatch_queue_t queue = dispatch_queue_create("com.emporium.catalog", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
        // Off-thread work. A traced call made from here is invisible to the recorder: this block runs
        // on a plain GCD thread, which carries no Swift task, so the `@TaskLocal` lookup finds nothing.
        if (notifier) {
            notifier();
        }
        NSArray<NSString *> *products = @[@"coffee", @"mug", @"beans"];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(products);
        });
    });
}

- (void)warmCache {
    // Returns immediately. The caller gets no handle and no completion, so a harness has nothing to
    // wait on before snapshotting its trace.
    dispatch_queue_t queue = dispatch_queue_create("com.emporium.cache", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
        if (self.cacheWarmedHandler) {
            self.cacheWarmedHandler();
        }
    });
}

@end
