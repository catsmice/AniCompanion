#import "ObjCExceptionCatcher.h"

@implementation ObjC

+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:exception.name
                                         code:0
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"Unknown Objective-C exception"
            }];
        }
        return NO;
    }
}

@end
