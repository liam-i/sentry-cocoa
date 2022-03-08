#import "SentryANRTracker.h"
#import "SentryCrashAdapter.h"
#import "SentryDispatchQueueWrapper.h"
#import "SentryLog.h"
#import "SentryThreadWrapper.h"
#import <Foundation/Foundation.h>

@interface
SentryANRTracker ()

@property (weak, nonatomic) id<SentryANRTrackerDelegate> delegate;
@property (nonatomic, assign) NSTimeInterval timeoutInterval;
@property (nonatomic, strong) id<SentryCurrentDateProvider> currentDate;
@property (nonatomic, strong) SentryCrashAdapter *crashAdapter;
@property (nonatomic, strong) SentryDispatchQueueWrapper *dispatchQueueWrapper;
@property (nonatomic, strong) SentryThreadWrapper *threadWrapper;

@property (weak, nonatomic) NSThread *thread;

@end

@implementation SentryANRTracker

- (instancetype)initWithDelegate:(id<SentryANRTrackerDelegate>)delegate
           timeoutIntervalMillis:(NSUInteger)timeoutIntervalMillis
             currentDateProvider:(id<SentryCurrentDateProvider>)currentDateProvider
                    crashAdapter:(SentryCrashAdapter *)crashAdapter
            dispatchQueueWrapper:(SentryDispatchQueueWrapper *)dispatchQueueWrapper
                   threadWrapper:(SentryThreadWrapper *)threadWrapper
{
    if (self = [super init]) {
        self.delegate = delegate;
        self.timeoutInterval = (double)timeoutIntervalMillis / 1000;
        self.currentDate = currentDateProvider;
        self.crashAdapter = crashAdapter;
        self.dispatchQueueWrapper = dispatchQueueWrapper;
        self.threadWrapper = threadWrapper;
    }
    return self;
}

- (void)start
{
    [NSThread detachNewThreadSelector:@selector(detectANRs) toTarget:self withObject:nil];
}

- (void)detectANRs
{
    NSThread.currentThread.name = @"io.sentry.anr-tracker";

    self.thread = NSThread.currentThread;

    BOOL wasPreviousANR = NO;

    while (![self.thread isCancelled]) {

        NSDate *blockDeadline =
            [[self.currentDate date] dateByAddingTimeInterval:self.timeoutInterval];

        __block BOOL blockExecutedOnMainThread = NO;
        [self.dispatchQueueWrapper dispatchOnMainQueue:^{ blockExecutedOnMainThread = YES; }];

        [self.threadWrapper sleepForTimeInterval:self.timeoutInterval];

        if (blockExecutedOnMainThread) {
            wasPreviousANR = NO;
            continue;
        }

        if (wasPreviousANR) {
            [SentryLog logWithMessage:@"Ignoring ANR because ANR is still ongoing."
                             andLevel:kSentryLevelDebug];
            continue;
        }

        // The blockDeadline should be roughly executed after the timeoutInterval even if there is
        // an ANR. If the app gets suspended this thread could sleep and wake up again. To avoid
        // false positives, we don't report ANRs if the delta is too big.
        NSTimeInterval deltaFromNowToBlockDeadline =
            [[self.currentDate date] timeIntervalSinceDate:blockDeadline];

        if (deltaFromNowToBlockDeadline >= self.timeoutInterval) {
            continue;
        }

        // Ignore background state if the runloop has not yet ticked so that hangs in
        // `didFinishLaunching` in UIScene-based apps are detected. UIScene-based apps always
        // start in UIApplicationStateBackground, unlike those without scenes.

        if (![self.crashAdapter isApplicationInForeground]) {
            [SentryLog logWithMessage:@"Ignoring ANR because the app is in the background"
                             andLevel:kSentryLevelDebug];
            continue;
        }

        wasPreviousANR = YES;
        [self.delegate anrDetected];
    }
}

- (void)stop
{
    [self.thread cancel];
}

@end
