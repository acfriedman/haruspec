#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A legacy Cocoa-style enumerator: the `BOOL *stop` block shape of `-enumerateObjectsUsingBlock:`.
/// The stop flag lives in this method's own stack frame, so a Swift port hands its block a different
/// address for the same flag. This fixture stands in for a real legacy subject with an enumeration API.
@interface LegacyInventory : NSObject

/// An inventory that enumerates `items` in order.
- (instancetype)initWithItems:(NSArray<NSString *> *)items NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Calls `block` with each item in order, and stops after the call that sets `*stop` to `YES`.
- (void)enumerateItemsUsingBlock:(void (^)(NSString *item, BOOL *stop))block;

@end

NS_ASSUME_NONNULL_END
