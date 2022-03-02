#import "SentryANRTracker.h"
#import "SentryCrashAdapter.h"
#import "SentryCrashMonitor_AppState.h"
#import "SentryLog.h"
#import <Foundation/Foundation.h>

@interface
SentryANRTracker ()

@property (nonatomic, strong) SentryCrashAdapter *crashAdapter;
@property (nonatomic, assign) NSUInteger timeoutIntervalMillis;

@property (nonatomic) BOOL runLoopIsRunning;
@property (nonatomic) BOOL recordAllThreads;
@property (nullable, nonatomic) CFRunLoopObserverRef observer;
@property (nonatomic) dispatch_semaphore_t processingEventStarted;
@property (nonatomic) dispatch_semaphore_t processingEventFinished;
@property (weak, nonatomic) NSThread *thread;

@end

@implementation SentryANRTracker

- (instancetype)initWithTimeoutIntervalMillis:(NSUInteger)timeoutIntervalMillis
                                 crashAdapter:(SentryCrashAdapter *)crashAdapter
{
    if (self = [super init]) {
        self.timeoutIntervalMillis = timeoutIntervalMillis;
        self.crashAdapter = crashAdapter;
    }
    return self;
}

- (void)start
{
    self.processingEventStarted = dispatch_semaphore_create(0);
    self.processingEventFinished = dispatch_semaphore_create(0);

    __block BOOL isProcessing = NO;

    void (^observerBlock)(CFRunLoopObserverRef, CFRunLoopActivity)
        = ^(__attribute__((unused)) CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            [SentryLog logWithMessage:@"activity"
                             andLevel:kSentryLevelDebug];
              // Before processing an event, the run loop can be in two different states: sleeping
              // or just finished processing a previous event, meaning being busy. When sleeping,
              // the run loop calls kCFRunLoopAfterWaiting before processing an event, and when
              // being busy, it calls kCFRunLoopBeforeTimers and kCFRunLoopBeforeSources before
              // processing an event. Therefore we have to watch out for both kCFRunLoopAfterWaiting
              // and kCFRunLoopBeforeSources. Checkout
              // https://suelan.github.io/2021/02/13/20210213-dive-into-runloop-ios/
              if (activity == kCFRunLoopAfterWaiting || activity == kCFRunLoopBeforeSources) {
                  if (isProcessing) {
                      // When busy, a run loop can go through many timers / sources iterations
                      // before kCFRunLoopBeforeWaiting. Each iteration indicates a separate unit of
                      // work so the hang detection should be reset accordingly.
                      dispatch_semaphore_signal(self.processingEventFinished);
                  }

                  self.runLoopIsRunning = YES;
                  dispatch_semaphore_signal(self.processingEventStarted);
                  isProcessing = YES;
                  return;
              }

              // Thread is about to sleep
              if (activity == kCFRunLoopBeforeWaiting) {
                  if (isProcessing) {
                      dispatch_semaphore_signal(self.processingEventFinished);
                      isProcessing = NO;
                  }
                  return;
              }
          };

    // A high `order` is required to ensure our kCFRunLoopBeforeWaiting observer runs after others
    // that may introduce an app hang. Once such culprit is -[UITableView
    // tableView:didSelectRowAtIndexPath:] which is run in a _afterCACommitHandler, which is invoked
    // via a CFRunLoopObserver.
    CFIndex order = INT_MAX;
    CFRunLoopActivity activities
        = kCFRunLoopAfterWaiting | kCFRunLoopBeforeSources | kCFRunLoopBeforeWaiting;
    self.observer
        = CFRunLoopObserverCreateWithHandler(NULL, activities, true, order, observerBlock);

    dispatch_semaphore_signal(self.processingEventStarted);
    isProcessing = YES;

    CFRunLoopAddObserver(CFRunLoopGetMain(), self.observer, kCFRunLoopCommonModes);

    [NSThread detachNewThreadSelector:@selector(detectANRs) toTarget:self withObject:nil];
}

- (void)detectANRs
{
    NSThread.currentThread.name = @"io.sentry.anr-tracker";

    self.thread = NSThread.currentThread;

    while (!NSThread.currentThread.isCancelled) {
        if (dispatch_semaphore_wait(self.processingEventStarted, DISPATCH_TIME_FOREVER) != 0) {
            [SentryLog logWithMessage:@"dispatch_semaphore_wait failed."
                             andLevel:kSentryLevelError];
            return;
        }

        const NSTimeInterval threshold = self.timeoutIntervalMillis / 1000;
        dispatch_time_t processingEventDeadline
            = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(threshold * NSEC_PER_SEC));

        if (dispatch_semaphore_wait(self.processingEventFinished, processingEventDeadline) == 0) {
            // Run loop finished within the deadline
            continue;
        }

        BOOL shouldReportAppHang = YES;

        if (dispatch_time(DISPATCH_TIME_NOW, 0)
            > dispatch_time(processingEventDeadline, 1 * NSEC_PER_SEC)) {
            // If this thread has woken up long after the deadline, the app may have been suspended.
            //            bsg_log_debug(@"Ignoring potential false positive app hang");
            shouldReportAppHang = NO;
        }

        // Ignore background state if the runloop has not yet ticked so that hangs in
        // `didFinishLaunching` in UIScene-based apps are detected. UIScene-based apps always start
        // in UIApplicationStateBackground, unlike those without scenes.
        if (shouldReportAppHang && !sentrycrashstate_currentState()->applicationIsInForeground
            && self.runLoopIsRunning) {
            [SentryLog logWithMessage:@"Ignoring app hang because app is in the background"
                             andLevel:kSentryLevelDebug];
            shouldReportAppHang = NO;
        }

        if (shouldReportAppHang) {
            [self anrDetected];
        }

        dispatch_semaphore_wait(self.processingEventFinished, DISPATCH_TIME_FOREVER);

        if (shouldReportAppHang) {
            [self anrEnded];
        }
    }
}

- (void)anrDetected
{
    [SentryLog logWithMessage:@"ANR detected." andLevel:kSentryLevelInfo];
}

- (void)anrEnded
{
    [SentryLog logWithMessage:@"ANR has ended." andLevel:kSentryLevelInfo];
}

- (void)stop
{
    [self.thread cancel];
    dispatch_semaphore_signal(self.processingEventStarted);
    dispatch_semaphore_signal(self.processingEventFinished);
    if (self.observer) {
        CFRunLoopObserverInvalidate(self.observer);
        self.observer = nil;
    }
}

@end
