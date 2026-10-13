#import "LegacyInventory.h"

@implementation LegacyInventory {
    NSArray<NSString *> *_items;
}

- (instancetype)initWithItems:(NSArray<NSString *> *)items {
    if ((self = [super init])) {
        _items = [items copy];
    }
    return self;
}

- (void)enumerateItemsUsingBlock:(void (^)(NSString *item, BOOL *stop))block {
    BOOL stop = NO;
    for (NSString *item in _items) {
        block(item, &stop);
        if (stop) {
            break;
        }
    }
}

@end
