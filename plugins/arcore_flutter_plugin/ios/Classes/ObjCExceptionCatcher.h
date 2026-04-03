#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Utility to catch Objective-C NSExceptions that bypass Swift's do/catch.
/// Used to safely attempt GARSession initialization on unsupported devices (iPad).
@interface ObjCExceptionCatcher : NSObject

/// Executes the tryBlock. If an NSException is thrown, returns the exception.
/// If no exception is thrown, returns nil.
+ (nullable NSException *)catchExceptionInBlock:(void (NS_NOESCAPE ^)(void))tryBlock;

@end

NS_ASSUME_NONNULL_END
