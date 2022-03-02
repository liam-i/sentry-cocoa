#import "SentryDefines.h"

@class SentryOptions, SentryCrashAdapter;

NS_ASSUME_NONNULL_BEGIN

@interface SentryANRTracker : NSObject
SENTRY_NO_INIT

- (instancetype)initWithTimeoutIntervalMillis:(NSUInteger)timeoutIntervalMillis
                                 crashAdapter:(SentryCrashAdapter *)crashAdapter;

- (void)start;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
