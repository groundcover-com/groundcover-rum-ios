<p align="center">
  <img src="https://cdn.jsdelivr.net/npm/@groundcover/browser/assets/logo.png" alt="groundcover" width="240" />
</p>

<h1 align="center">RUM — iOS SDK</h1>

groundcover's Real User Monitoring (RUM) SDK for native iOS apps, in Swift and Objective-C. It sends
the same `/json/rum` format as [`@groundcover/browser`](https://www.npmjs.com/package/@groundcover/browser),
[`@groundcover/react-native`](https://www.npmjs.com/package/@groundcover/react-native) and
[`groundcover_rum`](https://pub.dev/packages/groundcover_rum) (Flutter), so iOS sessions land in the
same RUM views as your web, React Native and Flutter sessions.

This package is published to
[`groundcover-rum-ios`](https://github.com/groundcover-com/groundcover-rum-ios), which each release
writes from [`packages/ios`](https://github.com/groundcover-com/groundcover-rum/tree/main/packages/ios)
in [groundcover-com/groundcover-rum](https://github.com/groundcover-com/groundcover-rum). Open issues
and pull requests there.

The SDK captures sessions, network requests with distributed tracing, screens, taps, gestures and
text-field edits, handled errors, logs, custom events and user identity. Through a native engine
compiled into the package it also captures **crashes, app hangs, app start and time to
interactive, and frame vitals**. Privacy masking is **on by default**.

> **Release candidate.** Session replay is not included.

See the [groundcover RUM documentation](https://docs.groundcover.com/investigate/real-user-monitoring-rum)
for the product guide; this README is the iOS SDK's documentation.

---

## Table of contents

- [Requirements](#requirements)
- [Install](#install)
- [Before you start](#before-you-start)
- [Quick start](#quick-start)
- [Configuration reference](#configuration-reference)
- [Privacy & data masking](#privacy--data-masking)
- [What is captured](#what-is-captured)
- [Network capture](#network-capture)
- [Logs](#logs)
- [Errors](#errors)
- [Native features](#native-features)
- [Session lifecycle](#session-lifecycle)
- [Coverage & limitations](#coverage--limitations)
- [Objective-C](#objective-c)
- [Apple privacy manifest](#apple-privacy-manifest)
- [Testing your app](#testing-your-app)
- [API reference](#api-reference)

---

## Requirements

| | |
|---|---|
| iOS | 15.0 or later |
| Swift tools | 5.9, so Xcode 15 or later |
| [KSCrash](https://github.com/kstenerud/KSCrash) | `2.2.0` up to, not including, `3.0.0`. If your app already depends on KSCrash, its version must fall in this range |
| [swift-log](https://github.com/apple/swift-log) | `1.5.0` up to, not including, `2.0.0`. Linked only by the `GroundcoverRumSwiftLog` product |

---

## Install

The SDK is a Swift package. In Xcode, choose **File → Add Package Dependencies…**, enter
`https://github.com/groundcover-com/groundcover-rum-ios`, pick version `0.0.1-rc.2`, and add the
`GroundcoverRum` product to your app target. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/groundcover-com/groundcover-rum-ios", from: "0.0.1-rc.2"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [.product(name: "GroundcoverRum", package: "groundcover-rum-ios")]
    ),
]
```

| Product | Add it when |
|---|---|
| `GroundcoverRum` | Always. The SDK, with an [Apple privacy manifest](#apple-privacy-manifest). |
| `GroundcoverRumObjC` | Your app calls the SDK from Objective-C or Objective-C++. See [Objective-C](#objective-c). |
| `GroundcoverRumSwiftLog` | Your app logs through swift-log, and you want those lines as log events. See [Logs](#logs). |

---

## Before you start

`Groundcover.start` needs three values from your groundcover account:

- **`apiKey`**: an ingestion key of type **RUM**, from **Settings → Access → Ingestion Keys**.
- **`dsn`**: your groundcover ingestion endpoint, such as `https://example.platform.grcv.io`. A bare
  host gets `https://`. Batches go to `{dsn}/json/rum`, so leave off a trailing slash.
- **`cluster`**: the cluster name your RUM data is filtered by.

And two that describe your app: **`environment`** (such as `production` or `staging`, sent as
`env`), and **`appId`**, the application's identity, sent as `service.name` and `app.id`. `appId`
must not be blank, and is fixed at start.

---

## Quick start

Start the SDK as early as you can, in `application(_:didFinishLaunchingWithOptions:)`:

```swift
import GroundcoverRum
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            try Groundcover.start(GroundcoverConfig(
                apiKey: "your-rum-ingestion-key",
                dsn: "https://example.platform.grcv.io",
                cluster: "your-cluster",
                environment: "production",
                appId: "my-ios-app",
                releaseId: "1.0.0",
                options: GroundcoverOptions(
                    // Send distributed-tracing headers to your own API hosts:
                    tracing: TracingOptions(propagationUrls: ["https://api.myapp.com/*"])
                )))
        } catch {
            // The SDK couldn't start, and the app runs unmonitored.
            print("groundcover: \(error)")
        }
        return true
    }
}
```

A SwiftUI app adopts the same delegate (without its `@main`) through `@UIApplicationDelegateAdaptor`:

```swift
@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { HomeView() }
    }
}
```

- **`start` throws `GroundcoverInitError`** for an invalid configuration: a blank `appId`. Its
  `localizedDescription` is the reason. Catch it, as above, so a monitoring failure never keeps the
  app from opening. A second call does nothing.
- **It returns once the session is ready**, within a second at most, so `Groundcover.sessionId`
  holds the id when it returns. The other calls do their work off the main thread, and none of
  them throws.
- **Calls made before `start` are dropped.** The exception is `markAppInteractive`, which records
  when it was called whenever that is.
- **Nothing is sent until a user is there**: a touch, or a return to the foreground, confirms the
  session, so a launch nobody sees (a background fetch, a push) sends nothing. Crash reports from
  earlier launches go out at every launch. See [Session lifecycle](#session-lifecycle).

### Naming screens

Every event carries the screen it happened on (`screen: {name, key}`), and each screen change is a
`navigation` event, with `from_screen`, `from_key` and `duration_ms` for the screen left.

**UIKit view controllers are tracked automatically.** Each of your view controllers is a screen
when it appears, named after its class (`CheckoutViewController`), with a key per instance
(`CheckoutViewController-1`). Containers are not screens: navigation, tab bar, page, split and
hosting controllers (your subclasses included), and any controller that holds one of your own
controllers or a hosting controller. Apple's own controllers, such as an alert, are never screens.
When a sheet is dismissed, the screen under it is current again.

**SwiftUI views name themselves** with `groundcoverScreen(_:key:)`. A SwiftUI view without it isn't
a screen, and the screen before it stays current. Without a `key`, each view instance gets its own
(`Checkout-1`):

```swift
struct CheckoutView: View {
    var body: some View {
        Form { Text("Total") }
            .groundcoverScreen("Checkout")
    }
}
```

**Anything else**, such as a tab bar that switches content without a new view controller, calls
`startNavigation` and `endNavigation`. The screen is current from `startNavigation`, and the
`navigation` event is sent at `endNavigation` with both calls' metadata. A blank screen name is
never reported.

```swift
Groundcover.startNavigation("Checkout", metadata: ["from": "cart"])
// …
Groundcover.endNavigation()
```

`Groundcover.stopNavigationTracking()` stops the automatic sources (view controllers and
`groundcoverScreen`); manual navigations still report.

### Check that data arrives

1. Set `debug: true` in `GroundcoverOptions` for the first run. Errors are silent without it: a
   wrong key or `dsn` fails each batch with nothing in the console, and an empty `cluster` holds
   every event.
2. Run the app and **touch it once**: nothing is sent before a user is there.
3. Within about 10 seconds the Xcode console shows `[groundcover] Sending batch:` and the events. A
   `Network error while sending batch` line means the ingest refused the batch or couldn't be
   reached: check the key and the `dsn`.
4. In groundcover, open **RUM** and switch the dropdown in the header from **Web** to **Mobile**.

Turn `debug` off again for release builds. From there, enrich the data:

```swift
Groundcover.identifyUser(RumUser(id: "u_123", email: "user@example.com", organization: "acme"))
Groundcover.captureError(error, metadata: ["feature": "checkout"])
Groundcover.logger.warn("Payment retry", ["provider": "stripe", "attempt": 2])
Groundcover.sendCustomEvent("plan_upgraded", ["plan": "pro"])
```

---

## Configuration reference

`GroundcoverConfig` holds connection and identity at the top level, and every behavioural option
under `options`. Names follow the React Native and Flutter SDKs. Durations are `TimeInterval`
seconds, and every option is optional: nil means the default.

### `GroundcoverConfig`

| Field | Type | Required | Description |
|---|---|---|---|
| `apiKey` | `String` | ✅ | An ingestion key of type RUM. With an empty key nothing is sent. |
| `dsn` | `String` | ✅ | Your ingestion endpoint; a bare host gets `https://`. |
| `cluster` | `String` | ✅ | Target cluster. With an empty cluster, events are held, up to 500, rather than sent. |
| `environment` | `String` | ✅ | Deployment environment, sent as `env`. |
| `appId` | `String` | ✅ | The application's identity. Must not be blank. Fixed at start. |
| `namespace` | `String?` | — | Logical grouping for the app. |
| `releaseId` | `String?` | — | Release identifier, such as a version or a commit hash. |
| `user` | `RumUser?` | — | The user at start, as `identifyUser` sets it. |
| `sessionId` | `String?` | — | Start with this session id instead of a generated or stored one. A new id starts a new session; the stored id continues it, unless that session has expired. |
| `options` | `GroundcoverOptions` | — | Below. |

### `GroundcoverOptions`

| Option | Type | Default | Description |
|---|---|---|---|
| `enabledEvents` | `[RumEventName]?` | all | Which signals to capture. **Nil or empty means all.** Fixed at start. |
| `sessionSampleRate` | `Double?` | `1` | The share of sessions to record, from 0 to 1. Fixed at start. |
| `sessionMaxDuration` | `TimeInterval?` | 4 hours | Target longest session, from 1 minute to 8 hours. Outside that, a warning, and the default (or, in an update, the current value). |
| `debug` | `Bool?` | `false` | Logs what the SDK does, each batch included, with a `[groundcover]` prefix. Misconfiguration warnings print either way. |
| `excludedUrls` | `[URLPattern]?` | none | Requests network capture skips. The SDK's own uploads are always skipped. |
| `beforeSend` | `BeforeSend?` | none | Return `false` to drop an event. |
| `enrichEvent` | `EnrichEvent?` | none | Change an event before it is queued, and return it. |
| `privacy` | `PrivacyOptions?` | masking on | See [`PrivacyOptions`](#privacyoptions). |
| `tracing` | `TracingOptions?` | none | See [`TracingOptions`](#tracingoptions). |
| `transport` | `TransportOptions?` | see below | See [`TransportOptions`](#transportoptions). |
| `appVersion` | `String?` | `CFBundleShortVersionString` | Sent as `app.version`. Fixed at start. |
| `appBuild` | `String?` | `CFBundleVersion` | Sent as `app.build`. Fixed at start. |
| `native` | `NativeOptions?` | see below | See [`NativeOptions`](#nativeoptions). Fixed at start. |
| `hooks` | `NativeHooks` | all on | See [`NativeHooks`](#nativehooks). Fixed at start. |

#### `beforeSend` and `enrichEvent`

Both receive each `RumEvent` after redaction and enrichment. Its `type` is `interaction`,
`network`, `log`, `navigation`, `custom`, `exception` or `performance`; its `attributes` are
**dot-flattened** (a tap's label is `"interaction_target.label"`), except `screen`; its timestamps
are epoch nanoseconds. `beforeSend` runs first; `enrichEvent` may change anything but `type` and
`id`:

```swift
let options = GroundcoverOptions(
    beforeSend: { event in
        // Attributes are flat: read them with the dotted key.
        !(event.type == "network"
            && "\(event.attributes["url.full"] ?? "")".contains("/health"))
    },
    enrichEvent: { event in
        event.attributes["tenant"] = "acme"
        return event
    })
```

Both run off the main thread, and also on [crash reports](#crashes). A hook that throws drops the
event, and what a hook sends through `Groundcover` is dropped too.

#### `RumEventName`

`interaction` (taps, gestures, text-field edits), `network` (and its trace headers), `logs`,
`navigation` (the events only: screens are stamped on every event either way), `exceptions`
(`captureError`), `crashes`, `hangs`, `vitals` and `appStart` (app start and TTI). Custom events are
sent whatever `enabledEvents` says.

#### `URLPattern`

A `.regex(NSRegularExpression)` matches anywhere in the URL. A `.string` with `*` or `?` is a glob
matched anywhere in the URL (`*` any run of characters, `?` any one character); any other `.string`
must equal the whole URL. A string literal is a `.string`, and the URL matched is the request's
`URL.absoluteString`:

```swift
let options = GroundcoverOptions(
    excludedUrls: ["https://api.myapp.com/health", "*/analytics/*"])
```

#### `PrivacyOptions`

| Option | Type | Default | Description |
|---|---|---|---|
| `level` | `PrivacyLevel?` | `.maskSensitive` | `.maskSensitive`, `.maskAll` or `.allow`. See [Privacy & data masking](#privacy--data-masking). |
| `maskNetworkBodies` | `Bool?` | `true`¹ | Redact request and response bodies. |
| `maskNetworkQueryParams` | `Bool?` | `true`¹ | Redact URL query parameters, and strip `user:password@` from URLs. |
| `maskLogs` | `Bool?` | `true`¹ | Redact log messages and attributes. |
| `maskErrors` | `Bool?` | `true`¹ | Redact error and crash messages and metadata. Stack frames are sent as they are. |
| `sensitiveKeys` | `[String]?` | none | Extra case-insensitive key substrings to treat as sensitive. |
| `redact` | `Redactor?` | none | A per-value hook. See [The `redact` hook](#the-redact-hook). |
| `maskInteractionLabels` | `Bool?` | on only under `.maskAll` | Mask interaction labels, hints and values under any level. |

¹ Each `mask*` toggle defaults **on** unless `level` is `.allow`, which turns them all off.

#### `TracingOptions`

| Option | Type | Default | Description |
|---|---|---|---|
| `propagationUrls` | `[String]?` | none | URLs that get trace headers, each matched against the **whole** URL, with `*` as the only wildcard. |
| `propagationHeaders` | `[String]?` | `["traceparent"]` | Headers that carry the W3C trace context. When set, they replace `traceparent`: list it too to keep it. |
| `traceIdHeaderName` | `String?` | none | An extra header carrying the trace id, in decimal. |
| `spanIdHeaderName` | `String?` | none | An extra header carrying the span id, in decimal. |
| `origin` | `TracingOrigin?` | none | An extra header, `name: value`, on traced requests. |

#### `TransportOptions`

| Option | Type | Default | Description |
|---|---|---|---|
| `batchSize` | `Int?` | `10` | Events buffered before a batch is sent; `0` sends each event alone; negative means the default. Navigation, interaction and performance events never trigger a send on their own. |
| `batchTimeout` | `TimeInterval?` | 10 s | Longest a batch waits before it is sent anyway. Under a millisecond means the default. |
| `compression` | `Bool?` | `true` | Gzip outgoing batches. |

The buffer is also sent when the app goes to the background. A batch the ingest doesn't accept is
not retried.

#### `NativeOptions`

| Option | Type | Default | Description |
|---|---|---|---|
| `hangThreshold` | `TimeInterval?` | 2 s | How long the main thread must be blocked before a hang is reported. Outside 0.25 to 60 s, the default. |
| `vitalsMaxSegment` | `TimeInterval?` | 60 s | Longest a frame-vitals segment runs before it is closed anyway. Outside 1 to 300 s, the default. |
| `tti` | `TtiMode?` | `.auto` | What counts as interactive: `.auto` or `.manual`. See [Time to interactive](#time-to-interactive). |

#### `NativeHooks`

Each automatic hook is on by default, and can be turned off for an app whose own instrumentation
clashes with it, as in `GroundcoverOptions(hooks: NativeHooks(urlSession: false))`.

| Hook | What it does |
|---|---|
| `viewControllers` | Screens from your view controllers. `groundcoverScreen` works either way. |
| `touches` | Taps, gestures, and the touches that confirm a session. Off, only a return to the foreground or a text-field edit confirms one. |
| `textFields` | One `input` event per edit of a `UITextField` or `UITextView`. |
| `urlSession` | Network capture for URLSession. See [Network capture](#network-capture). |

#### `RumUser`

All fields optional: `id`, `email`, `name`, `role`, `organization` and `properties`
(`[String: Any]`). Only the fields you set are sent, under the session's `user`.

### Updating config at runtime

`Groundcover.updateConfig(GroundcoverConfigUpdate(...))` changes `apiKey`, `dsn`, `cluster`,
`environment`, `namespace`, `releaseId`, `user`, and through `GroundcoverOptionsUpdate`,
`sessionMaxDuration`, `debug`, `excludedUrls`, `beforeSend`, `enrichEvent`, `privacy`, `tracing` and
`transport`. The rest is fixed at start, when the hooks are installed and the sampling verdict is
drawn: `appId`, `sessionId` (use [`setSessionId`](#session-lifecycle)), `enabledEvents`,
`sessionSampleRate`, `appVersion`, `appBuild`, `native` and `hooks`.

Nil means "unchanged", and an empty string is ignored. `privacy`, `tracing` and `transport` merge
field by field; `excludedUrls` and the hooks are replaced whole, and a hook can be replaced but not
removed. `user: .set(...)`, like `identifyUser`, merges into the current identity (`properties` as
a whole); `.clear` removes it, as at a logout:

```swift
Groundcover.updateConfig(GroundcoverConfigUpdate(
    user: .clear,
    options: GroundcoverOptionsUpdate(transport: TransportOptions(batchSize: 20))))
```

---

## Privacy & data masking

Masking is **on by default** (`.maskSensitive`). One `level` is the master switch; the toggles in
[`PrivacyOptions`](#privacyoptions), `sensitiveKeys` and a `redact` hook refine it.

| `level` | Network, logs, errors | Interaction labels |
|---|---|---|
| `.maskSensitive` **(default)** | Sensitive values redacted by the patterns below: query parameters, headers, body fields, log attributes and error metadata by key, and `key=value`-style pairs in free text | Captured, except in [private views](#private-views) |
| `.maskAll` | As `.maskSensitive` | Also masked: every interaction's label, hint and value become `***` |
| `.allow` | Nothing redacted, except sensitive headers | Captured, except in private views |

> **Sensitive headers are always redacted, even under `.allow`**: `authorization`, `cookie`,
> `set-cookie`, and any header whose name contains `token`, `key`, `secret`, `passwd`, `password`,
> `auth`, `bearer` or `credential` keep their name, with the value `[REDACTED]`.
>
> **Typed text is never captured at any level.** An `input` event records that a field was edited
> and which one, never its value, and a touch on the keyboard is never reported as a tap.

Navigation metadata is redacted by key too, except under `.allow`. **Custom events are not
redacted**: scrub `sendCustomEvent`'s attributes in `enrichEvent` if they can carry personal data.

```swift
let options = GroundcoverOptions(
    privacy: PrivacyOptions(
        sensitiveKeys: ["account_no"],
        maskInteractionLabels: true  // mask labels without going all the way to maskAll
    ))
```

### Built-in sensitive patterns

Matched case-insensitively; your `sensitiveKeys` are added on top.

- **Key substrings** in body, query and attribute keys: `token`, `secret`, `passwd`, `password`,
  `api_key`, `access_key`, `write_key`, `auth`, `bearer`, `credential`, `cvv`, `ssn`,
  `credit_card`, `card_number`. In `api_key`, `access_key`, `write_key`, `credit_card` and
  `card_number` the `_` may also be `-` or nothing.
- **Whole query and form keys**, never inside JSON bodies, which covers an OAuth callback: `code`,
  `state`, `session_state`, `id_token`, `access_token`, `refresh_token`, `token`.
- **Headers**, as above.

A sensitive key whose value is an object or a list is redacted whole, and so is anything nested
deeper than 8 levels.

### Private views

Mark a region private to mask its interaction labels **under any level**. Every interaction inside
it (taps, gestures and text-field edits) has its label, hint and value replaced with `***`, and so
does a control whose label would be read from text inside it. The role, component and component
path stay. It is the counterpart of React Native's `dataPrivate`.

```swift
// UIKit: this view and everything inside it.
profileCard.groundcoverPrivate = true

// SwiftUI: any element this view overlaps, and any touch inside it.
ProfileCard()
    .groundcoverPrivate()
```

### The `redact` hook

`redact` is called on **each leaf value** the redaction walk visits in headers, query parameters,
JSON and form bodies, log attributes, error metadata and navigation metadata. Return a replacement
string, number or `Bool`, or **nil to keep the SDK's default** (`[REDACTED]` when the field is
sensitive, the value otherwise). A hook that throws keeps the default too. Free text (a log, error
or crash message, a body that isn't JSON or a form) goes to the hook once, whole, with `key: ""`,
an empty `path` and `sensitive: false`; a non-nil return replaces the SDK's own scrub of that text.

```swift
let options = GroundcoverOptions(
    privacy: PrivacyOptions(
        redact: { field in
            // field.key, field.value, field.path, field.kind, field.sensitive
            if field.key == "email" { return "[email]" }
            return nil  // the SDK's default
        }))
```

`field.kind` is a `RedactKind`: `.requestBody`, `.responseBody`, `.query`, `.header`, `.log` or
`.error`. The hook runs off the main thread, and isn't called at all under `.allow`.

> **The hook overrides the built-in masking.** What it returns replaces `[REDACTED]`, sensitive
> headers included: a catch-all such as `redact: { $0.value }` sends `authorization`, `cookie` and
> every sensitive field as they are. Return nil for anything you don't handle.

---

## What is captured

| Event type | What | Source |
|---|---|---|
| `interaction` | `tap`, `long_press`, `swipe`, `scroll`, `pinch`, and `input` when a text field's edit ends | Every touch the app's windows receive, read after the app handled it; the text-field notifications |
| `network` | Method, URL, status, headers, bodies, timing and trace ids of each request | The URLSession hook and the [network API](#network-capture) |
| `log` | Lines at `log`, `info`, `warn`, `error`, `debug` and `trace` | `Groundcover.logger`, and swift-log through `GroundcoverLogHandler` |
| `exception` | Handled errors, crashes, app hangs (`AppHang`) | `captureError`; KSCrash, on the next launch; the hang watchdog |
| `navigation` | Screen changes | Your view controllers, `groundcoverScreen`, `startNavigation` / `endNavigation` |
| `performance` | `app_start_cold`, `app_start_hot`, `app_start_tti`, `frames_delay_total` | The native engine |
| `custom` | Your business events | `sendCustomEvent` |

### Interactions

| Interaction | When |
|---|---|
| `tap` | One finger, moved no more than 10 points, lifted within 500 ms |
| `long_press` | One finger, moved no more than 10 points, held longer than 500 ms |
| `swipe` | One finger, ending at least 32 points from where it started, released at 300 points/s or faster |
| `scroll` | As a swipe, released slower |
| `pinch` | Two or more fingers at once |
| `input` | A `UITextField` or `UITextView` was edited, and editing ended or a tap landed outside it |

A gesture the system cancelled is marked `partial`. A finger that moved more than 10 points but
ended less than 32 points from where it started is no interaction.

A target is named the way VoiceOver would name it. The accessibility element under the finger gives
the `label` (its accessibility label, else a button's title, else the text of the labels inside it,
never a text field's text), `role` (from its traits: `button`, `link`, `image`, `switch`,
`adjustable`, `textfield`, …), `hint`, `state` (`selected`, `disabled`) and `value`. Each event
carries them in `interaction_target`, with the view's class as `component`;
`interaction_component_path` (the innermost 10 view classes, from the outside in); and, except for
input, `interaction_coordinates` in points. Gestures other than a tap add `interaction_gesture`:
`direction`, `distance_dp`, `velocity_dp_s`, `duration_ms`, `pointer_count` and `partial`.

### Session attributes

Every batch carries `session_id`, `session_start_time`, `service.name` (the `appId`), `cluster`,
`env`, `namespace`, `releaseId`, `user`, `source: "mobile-rum"`, `os` (`ios` and its version),
`device` (`model`, the hardware identifier such as `iPhone15,2`; `brand: "Apple"`; `screen`, in
points with its scale and Dynamic Type scale), `app` (`id`, `version`, `build`) and
`sdk: {name: "groundcover-rum-ios", version}`.

---

## Network capture

### The URLSession hook

With `hooks.urlSession` on (the default), the SDK records every request URLSession's classic loader
sends, which is the default loader of every session. It hooks `URLSessionTask`'s `resume` and its
completion, so it needs no change to your code and covers completion handlers, delegates, `async`
calls, `URLSession.shared`, and clients built on URLSession, such as Alamofire: data, upload and
download tasks alike.

Each request is reported once, when it completes, with its method, URL, status, request and
response headers, request body, and timing from `resume` to completion. **The hook never reads a
response body**: it is reported as `[response body unavailable]`. An upload task's body, which the
task holds rather than its request, is named by its content type or reported unavailable.

**Not seen by the hook:** a session that sets `usesClassicLoadingMode = false`, stream and WebSocket
tasks, clients that don't use URLSession, and a task's second `resume` after a suspend. Record
those, and any request whose response body you want, through the network API.

### The network API

These record a request with its response body, and the hook doesn't record it a second time.
`URLSession.groundcoverDataTask(with:completionHandler:)` and `groundcoverData(for:)` stand in for
`dataTask(with:completionHandler:)` and `data(for:)`:

```swift
let (data, response) = try await URLSession.shared.groundcoverData(for: request)
```

For a session with a delegate, make the delegate a `GroundcoverURLSessionDelegate` (a subclass that
overrides its two methods calls `super`), and create tasks with `groundcoverDataTask(with:)`. For
any other client, start a recording, send the request as the call leaves it (with its trace
headers), and finish the recording when the request ends. `startNetworkRecording` returns nil, with
the request untouched, when the SDK isn't recording or doesn't capture the URL:

```swift
func load(_ url: URL, with client: MyHTTPClient) {
    var request = URLRequest(url: url)
    // Adds the trace headers; nil when the SDK doesn't record this URL.
    let recording = Groundcover.startNetworkRecording(&request)
    client.send(request) { response, data, error in
        recording?.finish(response: response, data: data, error: error)
    }
}
```

`finish(response:data:error:)` can be called from any thread; only the first call counts. Alamofire
requests are recorded by the hook already; to add their response bodies, start the recording in a
`RequestInterceptor`'s `adapt` and finish it from an `EventMonitor`'s
`request(_:didCompleteTask:with:)`, with `task.response`, the request's data and `task.error` (not
the `AFError` that wraps it).

### What a network event holds

- **Bodies** are kept when their content type is text (`text/*`, JSON, XML, form-urlencoded,
  JavaScript, GraphQL) and under 5,000 bytes. A larger one becomes `[request body too large]` or
  `[response body too large]`, never cut; multipart, `[form data]`; binary, or with no content type,
  a label such as `[image data]` or `[binary data]`; a request body sent as a stream,
  `[request body unavailable]`.
- **Failures** before a response are reported with status `0` and `error.type` `ERR_TIMEOUT` or
  `ERR_NETWORK_FAILURE`. A cancelled request isn't reported, except a server-sent event stream that
  had opened.
- **Headers** are reported with lower-case names, redacted as described in
  [Privacy & data masking](#privacy--data-masking).

### Trace header propagation

A request whose whole URL matches `tracing.propagationUrls` gets
`traceparent: 00-<trace id>-<span id>-01` (or your `propagationHeaders`), plus the
`traceIdHeaderName`, `spanIdHeaderName` and `origin` headers you configured. Only `*` is a wildcard,
so an unescaped `.` can't send your headers to a look-alike host. Names that aren't valid HTTP
header names are skipped.

**A request that already carries its own trace context keeps it.** When it has a value in a header
the SDK would set (`traceparent`, or your `propagationHeaders`), the SDK adds none of its headers,
and the network event takes its trace and span ids from that header, so it joins your trace.

Trace headers go only on requests the SDK captures: not on an `excludedUrls` match or the SDK's own
uploads, not with `network` out of `enabledEvents`, not before `start`, and not in a session that
isn't sampled.

---

## Logs

`Groundcover.logger` has one method per level, `log`, `info`, `warn`, `error`, `debug` and `trace`,
each taking a message and a dictionary of attributes:

```swift
Groundcover.logger.info("Checkout started", ["cart_size": 3])
Groundcover.logger.error("Payment failed", ["provider": "stripe"])
```

The attribute keys `message`, `level` and `screen` are the event's own and are dropped from yours.
A message longer than 10,000 characters is cut. Messages and attributes are redacted under
`maskLogs`. `print`, `NSLog` and `os_log` aren't captured.

### swift-log

Add the `GroundcoverRumSwiftLog` product, and bootstrap swift-log with `GroundcoverLogHandler` next
to the handler you already use:

```swift
import GroundcoverRumSwiftLog
import Logging

LoggingSystem.bootstrap { label in
    MultiplexLogHandler([
        StreamLogHandler.standardOutput(label: label),
        GroundcoverLogHandler(label: label),
    ])
}

let logger = Logger(label: "com.myapp.checkout")
logger.warning("Payment retry", metadata: ["attempt": "2"])
```

Each message becomes a log event, with the metadata as attributes and the label as `logger`;
`.notice` is sent as `info`, `.warning` as `warn`, `.critical` as `error`. Messages below the
handler's `logLevel` (`.info` by default), or containing `groundcoverIgnore`, aren't sent.

---

## Errors

Report a handled error with `captureError`. It sends an `exception` event with
`error_handled: true`, and needs `exceptions` in `enabledEvents`:

```swift
do {
    try await checkout()
} catch {
    Groundcover.captureError(error, metadata: ["step": "payment"])
}
```

`error_type` is `URLError`, `CocoaError`, `POSIXError` or `MachError` for those, an `NSError`'s
domain, else the Swift type's name. `error_message` is a `LocalizedError`'s `errorDescription`, an
`NSError`'s `localizedDescription`, else how Swift prints the error; it and `error_metadata` are
redacted under `maskErrors`. `error_stacktrace` is the stack of the call to `captureError` (a Swift
`Error` carries none of its own), up to 200 frames, each the binary image and the symbol with its
offset, or in a stripped binary the offset into the image.

**Uncaught errors are crashes.** An uncaught `NSException` or C++ exception, a Mach exception or a
fatal signal ends the process; KSCrash records it, and the SDK reports it on the next launch. See
[Crashes](#crashes).

---

## Native features

Crashes, app hangs, app start, time to interactive and frame vitals come from a native engine
compiled into the package, the one `@groundcover/react-native` and `groundcover_rum` run on iOS, so
these signals mean the same in every SDK. There is nothing to set up, and each has its own
`enabledEvents` name:

```swift
let options = GroundcoverOptions(
    // Leave a name out to turn that signal off. Nil or empty (the default): all.
    enabledEvents: [.interaction, .network, .logs, .navigation, .exceptions, .crashes],
    native: NativeOptions(
        hangThreshold: 1.5,  // seconds the main thread must be blocked
        tti: .manual))
```

### Crashes

[KSCrash](https://github.com/kstenerud/KSCrash) records Mach exceptions, fatal signals, and
uncaught C++ exceptions and `NSException`s. A crash ends the process, so the SDK sends it on the
**next launch, once `start` runs, under the session it happened in**, with the crash-time timestamp
and screen. It goes out at every launch, before any touch and even when the new launch isn't
sampled; a crash in a session that wasn't sampled is dropped.

Delivery is **at least once**: a report is deleted only after the ingest accepts it, so a crash on
a plane is reported when the app next runs with a network, and `error_metadata.crash_report_id` is
stable across attempts. Up to 10 reports wait on disk, the oldest dropped first. **Leaving
`crashes` out of `enabledEvents` stops capturing new crashes**: reports already taken from KSCrash
still go out, but KSCrash's own are read only while `crashes` is on.

`beforeSend` returning `false`, or throwing, drops a crash report for good; an `enrichEvent` that
throws costs only its changes. Messages and metadata are redacted under `maskErrors`.

A crash's `error_type` is the `NSException`'s name, else the Mach exception (such as
`EXC_BAD_ACCESS`), else the signal. Its frames start where an `NSException` or C++ exception was
thrown, else on the crashed thread. `error_metadata` has `native: true`, `fatal: true`,
`crash_report_id`, `crash_source: "kscrash"`, and when known `signal`, `signal_code`,
`mach_exception`, `fault_address`, `thread_count`, `crashed_thread`, `app_image_uuid`,
`app_image_load_address` and `foreground`.

**Another crash reporter built on KSCrash.** KSCrash is one per process. If another SDK installed
it first, this one leaves KSCrash's reports alone (reading them would delete the other SDK's), so
its crash capture is unavailable: it prints a `native crash capture is unavailable` warning, and
every other signal still runs. If this SDK installs first, the other can't install KSCrash.

### App hangs

A watchdog thread reads a heartbeat the main thread beats every 0.1 s. When the main thread has been
blocked past `hangThreshold` (2 s by default) and then recovers, the SDK sends an `exception` with
`error_type: AppHang`, `error_message: "Main thread blocked for 2101ms"`, `error_handled: false`
and `error_metadata` `{native: true, recovered: true, hang_duration_ms, hang_started_at}`, placed
when the stall began. Its fingerprint groups hangs by duration bucket (`<1s`, `2s` … `30s+`).

The watchdog looks every fifth of the threshold (0.1 to 1 s), so a stall is reported reliably once
it lasts the threshold plus one such interval. It sleeps while the app is in the background. A hang
the app never recovers from isn't reported, and an iOS hang carries no stack. On Android,
groundcover's SDKs report the same stall as `ANR`: query `error_type IN ("ANR", "AppHang")` to see
both.

### App start

- **`app_start_cold`**: process start to the first frame the app drew. A launch the system
  prewarmed is measured from when the SDK's code was loaded instead, with navigation type
  `cold_prewarmed`. A launch into the background, or one sent there before its first frame, has no
  cold start.
- **`app_start_hot`**: a return to the foreground (`willEnterForeground`) to the next frame. iOS
  reports no warm start.

Starts longer than 60 s are discarded. Each event carries `performance_metric_name`,
`performance_metric_value` (ms) and `performance_metric_navigation_type` (`cold`, `cold_prewarmed`
or `hot`), and waits up to 5 seconds for the first screen, so it carries the screen it landed on.

### Time to interactive

TTI (`app_start_tti`) runs from the cold start's anchor to the moment the app became **usable**,
and is never below the cold start. With `TtiMode.auto` (the default) that is the first named screen
becoming current: a floor, since it comes before that screen's data loads. With `TtiMode.manual`,
call `markAppInteractive()` once, when the first screen is genuinely ready:

```swift
// NativeOptions(tti: .manual), then, once the first screen's data has arrived:
Groundcover.markAppInteractive()
```

The time is taken at the call, even before `start`, and only the first call counts. A launch with
no cold start, and a hot start, have no TTI.

### Frame vitals

Frame vitals are measured **per screen**, from a display link on the main thread. The open
*segment* closes, and becomes one `frames_delay_total` performance event, when the user leaves the
screen (`performance_segment_reason: navigation`; it belongs to the screen left), when the app
leaves the foreground (`background`), or after `vitalsMaxSegment` (`safety`, 60 s by default).

The event's `performance_metric_value` is the milliseconds every slow frame took beyond the frame
budget, summed. It also carries `performance_frames_slow`, `performance_frames_frozen`,
`performance_refresh_rate_hz`, `performance_frame_budget_ms`, and the segment's bounds as
`start_timestamp` and `end_timestamp` (epoch nanoseconds). A frame is **slow** past one frame
interval plus a vsync's tolerance (`1000 / (refreshRate - 1)` ms at a fixed rate) and **frozen**
past 700 ms; an app hang counts as a frozen frame. To compare screens, divide by the segment's
length. A segment with no frames isn't reported, nor one drawn while the session was idle or
started before the current session.

---

## Session lifecycle

**Persistence.** The session's id, start, last activity and sampling verdict are stored in the
SDK's own `UserDefaults` suite, `com.groundcover.rum`, so a session survives app restarts.

**A session is confirmed by the user**: a finger going down anywhere (the keyboard included), a
return to the foreground, or a finished text-field edit. The launch itself isn't one. Until then up
to 500 events are held, the newest dropped past that, and a session that ends unconfirmed is
discarded with its buffer.

**Rotation is activity-driven, not timer-driven**:

- **After 30 minutes without the user**, the next sign of one starts a new session. The same check
  runs at `start`, so a launch after a long break starts a fresh one.
- **Past `sessionMaxDuration`** (4 hours by default), the next event other than a performance event
  starts a new session. Performance events (frame vitals, app start) never check the cap, so an
  idle app keeps its id past it until another event arrives.
- What the old session buffered is sent under its own id first, and the new session starts at the
  earliest event that belongs to it.

**Sampling** is drawn at `start` and stored with the session, so a session keeps its verdict across
restarts. A session that isn't sampled arms no hook, hang watchdog, frame tracker or app-start
tracking; crash capture stays armed, so crashes from earlier sampled sessions are still delivered.
A session that starts while the app runs is recorded for the rest of that process, and its verdict
is drawn at the next launch.

**Session id.** `Groundcover.sessionId` is the current id, or `""` before `start` and when the
session isn't sampled. `setSessionId` sends what the current session buffered (or discards it, if
nobody confirmed it) and starts a new session with your id or a generated one. It keeps the
sampling verdict, and the new session waits for a user like any other:

```swift
let id = Groundcover.sessionId  // "" before start, or when not sampled
await Groundcover.setSessionId("my-id")  // send the buffer, start this session
await Groundcover.setSessionId()  // the same, with a generated id
```

---

## Coverage & limitations

- **No session replay.**
- **One groundcover SDK per app.** An app that embeds React Native or Flutter screens can't also
  run groundcover's React Native or Flutter SDK: each would start its own crash reporter
  and session.
- **SwiftUI taps are named generically unless system accessibility is on.** SwiftUI draws no view
  per control, and builds the accessibility tree the SDK names targets from only while system
  accessibility (VoiceOver, for one) is on. Otherwise a tap on a SwiftUI button (a `NavigationLink`
  included) arrives as `component: "Button"`, `role: "button"` and no label, and other SwiftUI
  controls can arrive with neither. `groundcoverScreen` still places the tap. UIKit controls are
  named from their own properties either way.
- **The URLSession hook doesn't read response bodies**, and doesn't see sessions with
  `usesClassicLoadingMode = false`, stream or WebSocket tasks, or other clients. Use the
  [network API](#the-network-api) for those.
- **Logs come only from `Groundcover.logger` and swift-log**, not `print`, `NSLog` or `os_log`.
- **Hangs the app never recovers from aren't reported**, iOS hangs carry no stack, and iOS reports
  no warm start.
- **groundcover doesn't symbolicate iOS frames.** A frame in a stripped binary arrives as the image
  and the offset into it; crash events record `app_image_uuid` and `app_image_load_address` for the
  build's dSYM to resolve. Keep each release's dSYMs.
- **KSCrash below 2.6**: a C++ exception thrown in another binary image can leave the crash's stack
  empty or stale. From 2.6, it records where the exception was thrown.
- **Another KSCrash-based crash reporter** in the app means one of the two can't capture crashes.
- **Live batches aren't retried**; only crash reports are kept until delivered.
- **The Objective-C facade covers a subset** of the configuration.

---

## Objective-C

Add the `GroundcoverRumObjC` product. It exposes the SDK to Objective-C and Objective-C++ as
`Groundcover`, `GroundcoverConfig`, `GroundcoverUser`, `GroundcoverEvent`,
`GroundcoverPrivacyLevel`, `GroundcoverLogLevel` and `GroundcoverTesting`. `UIView`'s
`groundcoverPrivate` comes from `GroundcoverRum` itself.

```objc
@import GroundcoverRum;      // UIView.groundcoverPrivate
@import GroundcoverRumObjC;  // Groundcover, GroundcoverConfig, GroundcoverUser…

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  GroundcoverConfig *config =
      [[GroundcoverConfig alloc] initWithApiKey:@"your-rum-ingestion-key"
                                            dsn:@"https://example.platform.grcv.io"
                                        cluster:@"your-cluster"
                                    environment:@"production"
                                          appId:@"my-ios-app"];
  config.propagationUrls = @[ @"https://api.myapp.com/*" ];
  config.privacyLevel = GroundcoverPrivacyLevelMaskAll;
  config.hangThreshold = @1.5;  // seconds
  config.beforeSend = ^BOOL(GroundcoverEvent *event) {
    return ![event.type isEqualToString:@"performance"];
  };

  NSError *error = nil;
  if (![Groundcover startWithConfig:config error:&error]) {
    NSLog(@"groundcover: %@", error);  // the app runs unmonitored
  }
  return YES;
}
```

The other calls keep their Swift names: `identifyUser:` (with
`[[GroundcoverUser alloc] initWithId:]`), `clearUser`, `sendCustomEvent:attributes:`,
`captureError:metadata:`, `logWithLevel:message:attributes:` (with a `GroundcoverLogLevel`),
`sessionId`, `setSessionId:completion:`, `startNavigation:key:metadata:`, `endNavigation:`,
`stopNavigationTracking` and `markAppInteractive`; and `view.groundcoverPrivate = YES`.

- **`GroundcoverConfig`** has the options it supports as flat properties with their Swift names
  (`namespace` is `namespaceName`, a C++ keyword otherwise), plus `privacyLevel`,
  `manualTimeToInteractive`, `viewControllerHook`, `touchesHook`, `textFieldsHook` and
  `urlSessionHook`. A nil `NSNumber` means the default, and durations are seconds. `enabledEvents`
  takes the raw names, such as `@"appStart"`, and `excludedUrls` `NSString` and
  `NSRegularExpression` entries; anything else in those two fails `startWithConfig:error:`.
- **`beforeSend`** returns `NO` to drop an event; **`enrichEvent`** changes its `attributes` in
  place. Both run off the main thread and must not raise: an Objective-C exception can't be caught
  on its way back through Swift.
- **Not available from Objective-C:** `updateConfig` (other than `clearUser`), the `redact` hook,
  the per-surface privacy toggles, the tracing options other than `propagationUrls`, and the
  network API. The URLSession hook records Objective-C requests like any other.

---

## Apple privacy manifest

`GroundcoverRum` bundles a `PrivacyInfo.xcprivacy` (KSCrash's targets carry their own). It
declares:

- **Tracking:** `NSPrivacyTracking` is `false`, with no tracking domains.
- **Required-reason APIs:** UserDefaults, reason `CA92.1` (the session state, in the SDK's own
  `com.groundcover.rum` suite); file timestamps, reason `C617.1` (to evict the oldest pending crash
  reports, inside the app's container).
- **Collected data:** crash data, performance data and other diagnostic data, for app
  functionality; product interaction, user ID, email address and name, for app functionality and
  analytics. Every type is marked linked to the user, since once you identify users every event
  carries that identity, and none is used for tracking.

Xcode's privacy report (Organizer → Control-click an archive → **Generate Privacy Report**) merges
this with your app's other manifests. Use it as the starting point for your App Store privacy
labels: drop email or name if your app never sends them, and declare whatever `properties` holds.

---

## Testing your app

`GroundcoverRumTesting` has hooks for your tests and end-to-end harnesses, not for production code.

| Call | What it does |
|---|---|
| `reset()` | Stops the SDK: its hooks stay installed but go quiet, and the crash reporter stays armed. Buffered events are dropped, the stored session kept. A later `start` begins afresh. |
| `backdateLastActivity(by:)` | Sets the stored last activity to that many seconds ago: past 30 minutes, the next launch starts a new session. |
| `backdateSessionStart(by:)` | Sets the stored session start to that many seconds ago: past `sessionMaxDuration`, the next launch starts a new session. |
| `forgetSession()` | Forgets the stored session: id, start, last activity and sampling verdict. |
| `triggerTestCrash()` | Crashes the app with a real signal, to be reported on the next launch. |
| `blockMainThread(for:)` | Blocks the main thread for that many seconds, at most 30, so the hang watchdog fires. |

The session hooks show on the next launch. A running SDK writes its own last activity back when the app resigns or goes to the background, so call them after `reset()`, or end the app without backgrounding it. **`triggerTestCrash` and `blockMainThread` work in
development builds only** (a simulator, or a development provisioning profile), and do nothing in
App Store, Ad Hoc and Enterprise builds. In a test that starts the SDK, reset it when the test
ends:

```swift
import GroundcoverRum
import XCTest

final class CheckoutTests: XCTestCase {
    override func tearDown() {
        // Stops the SDK, so the next start begins afresh.
        GroundcoverRumTesting.reset()
        super.tearDown()
    }
}
```

---

## API reference

The public surface is in [`api/GroundcoverRum.swiftinterface`](api/GroundcoverRum.swiftinterface),
[`api/GroundcoverRumObjC.swiftinterface`](api/GroundcoverRumObjC.swiftinterface) and
[`api/GroundcoverRumSwiftLog.swiftinterface`](api/GroundcoverRumSwiftLog.swiftinterface). The calls
are static members of `Groundcover`; apart from `start`, none throws.

| Call | Description |
|---|---|
| `start(_:) throws` | Starts the SDK with a `GroundcoverConfig`; throws `GroundcoverInitError` for a blank `appId`. |
| `identifyUser(_:)` | Stamps a `RumUser` on every batch from now on, merged into the identity set before. |
| `updateConfig(_:)` | Changes what isn't [fixed at start](#updating-config-at-runtime); `user: .clear` forgets the user. |
| `sendCustomEvent(_:_:)` | A custom event with attributes. Not redacted, and sent whatever `enabledEvents` says. |
| `captureError(_:metadata:)` | Reports a handled error as an `exception` event. |
| `logger.{log,info,warn,error,debug,trace}(_:_:)` | Log events, through a `RumLogger`. |
| `sessionId` | The current session id: `""` before start, or when not sampled. |
| `setSessionId(_:) async` | Sends the current buffer and starts a new session. |
| `startNavigation(_:key:metadata:)` / `endNavigation(_:)` | Manual screen tracking. |
| `stopNavigationTracking()` | Stops the automatic screen sources. |
| `markAppInteractive()` | Marks the app usable, for TTI under `TtiMode.manual`. Counts before `start` too. |
| `startNetworkRecording(_:)` | Records a request sent by any client; returns a `GroundcoverNetworkRecording` to `finish`. |

The module also adds `URLSession`'s `groundcoverDataTask(with:completionHandler:)`,
`groundcoverDataTask(with:)` and `groundcoverData(for:)`, the `GroundcoverURLSessionDelegate`
class, `UIView.groundcoverPrivate`, and the SwiftUI modifiers `groundcoverScreen(_:key:)` and
`groundcoverPrivate(_:)`.

Release notes are in [CHANGELOG.md](CHANGELOG.md), and the license in [LICENSE](LICENSE).
