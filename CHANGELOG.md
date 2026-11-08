# Changelog

All notable changes to `GroundcoverRum`, groundcover's iOS RUM SDK, are documented here. This
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## [0.0.1-rc.0] — 2026-11-08

The first release candidate. It sends the same `/json/rum` format as groundcover's browser, React
Native and Flutter SDKs, so iOS sessions land in the same RUM views.

### Setup

- A Swift package for iOS 15 and later, with three products: `GroundcoverRum`, the SDK;
  `GroundcoverRumObjC`, for Objective-C and Objective-C++ apps; and `GroundcoverRumSwiftLog`, a
  swift-log `LogHandler`. It depends on KSCrash (`2.2.0..<3.0.0`) and swift-log (`1.5.0..<2.0.0`),
  and bundles an Apple privacy manifest.
- `try Groundcover.start(GroundcoverConfig(...))` in `application(_:didFinishLaunchingWithOptions:)`.
  It throws `GroundcoverInitError` for a blank `appId`, and returns once the session is ready;
  calls made before it are dropped.
- Automatic capture through four hooks (view controllers, touches, text fields, URLSession), each
  of which can be turned off in `NativeHooks`.
- `GroundcoverRumTesting` for an app's tests: `reset()` stops the SDK.
  `triggerTestCrash` and `blockMainThread` work in development builds only.

### Captured

- Sessions persisted across launches, with sampling, a presence gate (a touch or a return to the
  foreground) and rotation after 30 minutes without the user or past `sessionMaxDuration`.
- Network requests from every URLSession data, upload and download task the classic loader sends,
  without response bodies; and through `groundcoverDataTask`, `groundcoverData(for:)`,
  `GroundcoverURLSessionDelegate` and `startNetworkRecording`, with text bodies under 5,000 bytes.
  W3C `traceparent` propagation to `tracing.propagationUrls`; a request that carries its own trace
  context keeps it.
- Screens from your view controllers, SwiftUI views marked with `groundcoverScreen`, and manual
  `startNavigation` / `endNavigation`.
- Taps, long presses, swipes, scrolls and pinches from every touch the app's windows receive, named
  from the accessibility element under the finger; one `input` event per finished text-field edit,
  never the text.
- Handled errors through `captureError`; logs through `Groundcover.logger` and
  `GroundcoverLogHandler`; custom events; user identity.
- Crashes (Mach exceptions, signals, uncaught C++ exceptions and `NSException`s) through KSCrash,
  reported on the next launch under the session they happened in, even when that launch isn't
  sampled. Delivered at least once, with a stable `crash_report_id`.
- App hangs: main-thread stalls past `hangThreshold` (2 s by default) the app recovered from, as
  `exception` events with `error_type: AppHang`.
- App start: `app_start_cold` and `app_start_hot` to the first frame, and time to interactive
  (`app_start_tti`): the first screen landing, or `Groundcover.markAppInteractive()` with
  `NativeOptions(tti: .manual)`.
- Frame vitals: one `frames_delay_total` per screen segment, with slow and frozen frame counts.
- Privacy masking on by default: privacy levels, per-surface toggles, `sensitiveKeys`, a `redact`
  hook, and `groundcoverPrivate` for UIKit views and SwiftUI views. Typed text is never captured.

### Not included

- Session replay.
- Response bodies from the URLSession hook; use the network API for those.
- `print`, `NSLog` and `os_log` output.
- Warm starts, and hangs the app never recovers from.
- Symbolication of iOS stack frames.
- Running alongside groundcover's React Native or Flutter SDK in the same app.
