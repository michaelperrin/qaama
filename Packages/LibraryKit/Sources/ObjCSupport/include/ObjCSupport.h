#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns the Objective-C exception it raised, or nil when it completed.
/// Swift cannot catch NSException; some frameworks (PhotoKit with an unsupported predicate) raise one.
NSException *_Nullable QAACatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
