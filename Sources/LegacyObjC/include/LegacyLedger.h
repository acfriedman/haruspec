#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A legacy-style Objective-C singleton that performs a **silent side effect** — the motivating shape for
/// collaborator spying. `-reserveSku:quantity:` reserves stock on checkout and posts *nothing*: no
/// notification, no KVO, no return the caller inspects. On the observed trace alone, a Swift port that
/// drops the reserve call is indistinguishable from one that keeps it. This fixture stands in for a real
/// legacy inventory/analytics singleton the harness must be able to watch. Genuine ObjC dispatch makes
/// every method here swizzlable with no annotation.
@interface LegacyLedger : NSObject

/// A `dispatch_once` singleton — the common legacy shape.
+ (LegacyLedger *)sharedLedger;

/// The silent side effect: reserve `quantity` units of `sku`. Mutates internal state and returns void.
- (void)reserveSku:(NSString *)sku quantity:(NSInteger)quantity;

/// Total units reserved so far (test-inspection only; the spy records *calls*, not this accumulated state).
@property (nonatomic, readonly) NSInteger reservedTotal;

@end

NS_ASSUME_NONNULL_END
