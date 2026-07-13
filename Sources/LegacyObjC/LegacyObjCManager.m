#import "LegacyObjCManager.h"

@implementation LegacyObjCManager

+ (LegacyObjCManager *)shared {
    static LegacyObjCManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LegacyObjCManager alloc] init];
    });
    return instance;
}

- (NSString *)deviceToken {
    // Fresh every call — the un-injected nondeterminism the harness must pin. No annotation makes this
    // swizzlable: it already dispatches through objc_msgSend.
    return [[NSUUID UUID] UUIDString];
}

@end
