#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable NSException *)catchExceptionInBlock:(void (NS_NOESCAPE ^)(void))tryBlock {
    @try {
        tryBlock();
    }
    @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

@end
