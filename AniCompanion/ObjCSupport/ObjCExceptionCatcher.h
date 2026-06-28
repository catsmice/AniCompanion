#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C exceptions into Swift's error-handling model.
///
/// Some AVFoundation APIs (e.g. `AVAudioPlayerNode.play()`) can raise an
/// `NSException` rather than returning an error. Swift cannot catch those, so we
/// wrap the call in this helper and surface the failure as an `NSError`/`throws`.
@interface ObjC : NSObject

/// Executes `block` and catches any Objective-C exception, converting it to an `NSError`.
+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
