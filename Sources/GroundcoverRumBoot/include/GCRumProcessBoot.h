#import <Foundation/Foundation.h>

// Launch anchors stamped at load time (see GCRumProcessBoot.m). Declared in a
// header so Swift can read them — CocoaPods exposes a subspec's headers to its
// Swift sources automatically, no bridging header needed. The Flutter plugin's
// Swift package builds this unit as its own target (GroundcoverRumBoot), with
// this header under include/, and GCRumAppStartTracker imports it.

NS_ASSUME_NONNULL_BEGIN

/// Process start, read from the kernel. The only anchor available retroactively.
extern double GCRumProcessStartEpochMs(void);

/// When this library's code was loaded. The anchor for a prewarmed launch,
/// where process start can be minutes before the user opened the app.
extern double GCRumModuleLoadEpochMs(void);

extern double GCRumDidFinishLaunchingEpochMs(void);

/// When the first frame was drawn, or 0 if it has not happened yet.
extern double GCRumFirstFrameEpochMs(void);

/// Calls `handler` once the first frame is drawn, at once if it already has been. Main thread
/// only; the handler runs there too.
extern void GCRumOnFirstFrame(void (^handler)(void));

/// Whether iOS started this process ahead of the user opening the app.
extern BOOL GCRumWasPrewarmed(void);

/// Whether the app was in the background before its first frame was drawn.
extern BOOL GCRumBackgroundedBeforeFirstFrame(void);

NS_ASSUME_NONNULL_END
