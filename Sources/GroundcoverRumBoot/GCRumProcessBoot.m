#import "GCRumProcessBoot.h"
#import <stdatomic.h>

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <sys/sysctl.h>

// Timestamps that cannot be recovered later.
//
// By the time JavaScript calls init, launch is over: the process started, the
// app delegate ran, the first frame was drawn. Only process start can be read
// retroactively (the kernel keeps it); everything else has to be stamped as it
// happens. That is why this runs from a load-time constructor rather than from
// the engine, which does not exist until JavaScript initializes.
//
// The constructor itself takes timestamps ONLY — UIKit is not initialized
// during static construction. The first-frame display link is created from the
// didFinishLaunching observer, which is the earliest point where touching
// UIKit is safe and still ahead of the first frame.

static double gModuleLoadEpochMs = 0;
static double gDidFinishLaunchingEpochMs = 0;

// _Atomic, unlike the two above: this one is WRITTEN on the main thread by the display-link
// callback, long after launch, and READ from whatever thread `drain()` runs on when JavaScript
// arms the engine. The others are written once during static construction and are already
// published by the time any reader exists.
//
// Not merely tidiness. Without it the read is a data race — undefined by the memory model even
// where an aligned 64-bit load happens to be indivisible on the hardware — and the compiler is
// free to hoist or fold it. Relaxed ordering is enough: the value is self-contained, nothing else
// is published alongside it, and a reader that loses the race sees 0 and simply defers, which is
// exactly what the `> 0` guard in GCRumAppStartTracker already handles.
static _Atomic(double) gFirstFrameEpochMs = 0;
// Set on the main thread when the app is sent to the background before its first frame, read from
// the drain's thread: _Atomic for the same reason as the first frame.
static atomic_bool gSentToBackgroundBeforeFirstFrame = false;
static BOOL gWasPrewarmed = NO;
static BOOL gLaunchedInBackground = NO;
static CADisplayLink *gFirstFrameLink = nil;
// Main thread only, as the display link that calls them is.
static NSMutableArray<void (^)(void)> *gFirstFrameHandlers = nil;

@interface GCRumFirstFrameObserver : NSObject
+ (void)awaitFirstFrame;
@end

@implementation GCRumFirstFrameObserver

+ (void)awaitFirstFrame {
  if (gFirstFrameLink != nil ||
      atomic_load_explicit(&gFirstFrameEpochMs, memory_order_relaxed) != 0) {
    return;
  }
  gFirstFrameLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleFrame)];
  [gFirstFrameLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

+ (void)handleFrame {
  // The first tick IS the first drawn frame — the closest thing to "the user
  // can see something", which is what a launch duration should measure.
  if (atomic_load_explicit(&gFirstFrameEpochMs, memory_order_relaxed) == 0) {
    atomic_store_explicit(&gFirstFrameEpochMs,
                          [[NSDate date] timeIntervalSince1970] * 1000.0,
                          memory_order_relaxed);
  }
  [gFirstFrameLink invalidate];
  gFirstFrameLink = nil;

  NSArray<void (^)(void)> *handlers = gFirstFrameHandlers;
  gFirstFrameHandlers = nil;
  for (void (^handler)(void) in handlers) {
    handler();
  }
}

@end

/// Process start, straight from the kernel. The one anchor that survives being
/// asked for after the fact.
double GCRumProcessStartEpochMs(void) {
  struct kinfo_proc info;
  size_t size = sizeof(info);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};

  if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
    return 0;
  }

  struct timeval start = info.kp_proc.p_starttime;
  return (double)start.tv_sec * 1000.0 + (double)start.tv_usec / 1000.0;
}

double GCRumModuleLoadEpochMs(void) { return gModuleLoadEpochMs; }

double GCRumDidFinishLaunchingEpochMs(void) { return gDidFinishLaunchingEpochMs; }

/// When the first frame was drawn, or 0 if it has not happened yet.
double GCRumFirstFrameEpochMs(void) {
  return atomic_load_explicit(&gFirstFrameEpochMs, memory_order_relaxed);
}

/// Told by the display link that stamps the frame, rather than by a second link polling for the
/// stamp: two links on one frame tick in no set order.
void GCRumOnFirstFrame(void (^handler)(void)) {
  if (atomic_load_explicit(&gFirstFrameEpochMs, memory_order_relaxed) != 0) {
    handler();
    return;
  }
  if (gFirstFrameHandlers == nil) {
    gFirstFrameHandlers = [NSMutableArray array];
  }
  [gFirstFrameHandlers addObject:[handler copy]];
}

/// iOS may start a process ahead of the user opening the app. Measuring such a
/// launch from process start reports minutes of "startup" the user never
/// experienced, so it is classified separately and anchored at module load.
BOOL GCRumWasPrewarmed(void) { return gWasPrewarmed; }

/// Whether the app was in the background before its first frame was drawn: launched there (a
/// push, a background refresh), or sent there mid-launch. Either way process start to first frame
/// is no launch anyone waited through.
BOOL GCRumBackgroundedBeforeFirstFrame(void) {
  return gLaunchedInBackground ||
         atomic_load_explicit(&gSentToBackgroundBeforeFirstFrame, memory_order_relaxed);
}

/// Whether the system runs the process as the foreground app, from the task's role: a launch into
/// the background runs as a background role until the user opens the app. A role that can't be
/// read counts as foreground, so an unknown launch is still reported.
static BOOL GCRumTaskIsForegroundApp(void) {
  task_category_policy_data_t policy;
  mach_msg_type_number_t count = TASK_CATEGORY_POLICY_COUNT;
  boolean_t getDefault = FALSE;
  if (task_policy_get(mach_task_self(), TASK_CATEGORY_POLICY, (task_policy_t)&policy, &count,
                      &getDefault) != KERN_SUCCESS ||
      getDefault) {
    return YES;
  }
  return policy.role == TASK_FOREGROUND_APPLICATION;
}

__attribute__((constructor)) static void GCRumProcessBootInit(void) {
  gModuleLoadEpochMs = [[NSDate date] timeIntervalSince1970] * 1000.0;

  const char *prewarm = getenv("ActivePrewarm");
  gWasPrewarmed = (prewarm != NULL && strcmp(prewarm, "1") == 0);
  // Read now, before the user can open the app and turn the role foreground. A prewarmed process
  // isn't the foreground app yet either, and has a start of its own.
  gLaunchedInBackground = !gWasPrewarmed && !GCRumTaskIsForegroundApp();

  // Registered here, not in the engine: the engine is constructed from
  // JavaScript's init, long after this notification has already fired.
  [[NSNotificationCenter defaultCenter]
      addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification *_Nonnull note) {
                if (gDidFinishLaunchingEpochMs == 0) {
                  gDidFinishLaunchingEpochMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
                }
                // Earliest point where touching UIKit is safe, and still ahead
                // of the first frame.
                [GCRumFirstFrameObserver awaitFirstFrame];
              }];

  // Sent to the background mid-launch, before the first frame: the launch is dropped on this
  // signal. A launch into the background never gets it, since the app was never in the
  // foreground; the task role above covers that. Posted on the main thread, as the first-frame
  // stamp is, so the two can't interleave.
  [[NSNotificationCenter defaultCenter]
      addObserverForName:@"UIApplicationDidEnterBackgroundNotification"
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification *_Nonnull note) {
                if (atomic_load_explicit(&gFirstFrameEpochMs, memory_order_relaxed) == 0) {
                  atomic_store_explicit(&gSentToBackgroundBeforeFirstFrame, true,
                                        memory_order_relaxed);
                }
              }];
}
