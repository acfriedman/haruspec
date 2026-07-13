#import "LegacyLedger.h"

@implementation LegacyLedger {
    NSInteger _reservedTotal;
}

+ (LegacyLedger *)sharedLedger {
    static LegacyLedger *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LegacyLedger alloc] init];
    });
    return instance;
}

- (void)reserveSku:(NSString *)sku quantity:(NSInteger)quantity {
    // A real side effect with no observable signal — the blind spot the collaborator spy closes.
    _reservedTotal += quantity;
}

- (NSInteger)reservedTotal {
    return _reservedTotal;
}

@end
