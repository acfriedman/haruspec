#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A genuine legacy-style Objective-C singleton — the kind of un-annotatable dependency a Swift macro
/// can't touch (there is no Swift source to rewrite), but which ObjC's dynamic dispatch makes swizzlable
/// *by default*, with no `dynamic` annotation. This is a test fixture standing in for real legacy code.
@interface LegacyObjCManager : NSObject

/// A `dispatch_once` singleton with an immutable accessor — the common legacy shape.
@property (class, readonly, strong) LegacyObjCManager *shared;

/// The seam: returns a fresh value every call (nondeterministic), like a device/session token.
- (NSString *)deviceToken;

@end

NS_ASSUME_NONNULL_END
