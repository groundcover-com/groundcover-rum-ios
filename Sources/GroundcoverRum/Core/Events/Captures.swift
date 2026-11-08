// What capture hands the pipeline: typed records, so value sets that are closed are enums, never
// open strings.

/// `Groundcover.sendCustomEvent`. Not auto-redacted, by contract: scrub it in `enrichEvent` if it
/// can carry personal data.
struct CustomEventCapture {
    var name: String
    var attributes: [String: Any]

    /// When it happened, in nanoseconds since the epoch. Nil means "now".
    var timestampNs: Int64?
}

/// A log event's level: `Groundcover.logger`'s methods, and `log` for a line captured from the
/// platform's own logging.
enum LogLevel: String {
    case log, info, warn, error, debug, trace
}

/// A log line, from `Groundcover.logger` or captured from the platform's own logging. Redacted
/// under the log privacy rules.
struct LogCapture {
    var message: String
    var level: LogLevel
    var attributes: [String: Any]?
    var timestampNs: Int64?
}

/// Why a request failed before a response.
enum NetworkErrorType {
    case networkFailure
    case timeout

    /// The `error_type` the other SDKs send.
    var wireName: String {
        switch self {
        case .networkFailure: return "ERR_NETWORK_FAILURE"
        case .timeout: return "ERR_TIMEOUT"
        }
    }
}

/// One request, as capture saw it. Headers and bodies are raw; the pipeline redacts, truncates and
/// shapes them.
struct NetworkCapture {
    var method: String
    var url: String

    /// When the request started, and when its whole response, body included, or its failure
    /// arrived, as the browser's XHR and RN time a request. Milliseconds since the epoch.
    var startMs: Int64
    var endMs: Int64

    /// 0 for a request that failed before a response.
    var status: Int?
    var requestHeaders: [String: String] = [:]

    /// The text, or a placeholder from ``BodyPlaceholder``.
    var requestBody = ""
    var responseHeaders: [String: String] = [:]
    var responseBody = ""

    /// Set only for a request that failed before a response.
    var errorType: NetworkErrorType?
}

/// One stack frame, as the wire's `error_stacktrace` carries it.
struct ErrorFrame {
    var filename: String
    var function: String
    var lineno: Int
    var colno: Int

    var json: [String: Any] {
        ["filename": filename, "function": function, "lineno": lineno, "colno": colno]
    }
}

/// An error, reported by the app (`captureError`) or caught by the SDK.
struct ErrorCapture {
    /// The error's type name, the grouping key with `message`.
    var type: String
    var message: String

    /// Parsed by the capture layer. Diagnostic, and never redacted.
    var frames: [ErrorFrame] = []

    /// Reported by the app rather than caught by the SDK.
    var handled = false

    var metadata: [String: Any]?
    var timestampNs: Int64?
}

/// Which stall a hang is: iOS's app hang or Android's ANR, each under its platform's own name.
enum HangKind {
    case appHang
    case anr

    var wireName: String {
        switch self {
        case .appHang: return "AppHang"
        case .anr: return "ANR"
        }
    }
}

/// A main-thread stall the app recovered from, from the native engine's watchdog. One that killed
/// the process arrives with the next launch's crash records instead.
struct HangCapture {
    var kind: HangKind

    /// When the stall began, in epoch milliseconds: the event is placed there, before the taps and
    /// navigations it blocked, not at the recovery that reported it.
    var startedAtMs: Double
    var durationMs: Double

    /// The main thread's stack, which only Android captures.
    var frames: [ErrorFrame] = []
}

/// The launch metrics, by the name each ships under.
enum AppStartMetric: String {
    case cold = "app_start_cold"
    case warm = "app_start_warm"
    case hot = "app_start_hot"
    case tti = "app_start_tti"
}

/// One launch metric, measured by the native engine (the start) and the app (time to interactive).
struct AppStartCapture {
    var metric: AppStartMetric

    /// Milliseconds from the launch's start.
    var valueMs: Int64

    /// The engine's start type (`cold`, `cold_prewarmed`, `warm`, `hot`).
    var navigationType: String
}

/// Why a frame segment ended.
enum FrameSegmentReason: String {
    /// The screen changed.
    case navigation

    /// The app left the foreground.
    case background

    /// It ran past the segment cap (``NativeOptions/vitalsMaxSegment``).
    case safety
}

/// The frames drawn on one screen between two boundaries: a screen change, a trip to the
/// background, or the cap. Carries the screen it was drawn on, which on a screen change is the one
/// being left, not the current one.
struct FrameSegmentCapture {
    /// The segment's bounds, in epoch milliseconds.
    var startMs: Int64
    var endMs: Int64

    /// Frames drawn; never sent (platforms don't count the same frames), only used to drop an
    /// empty segment.
    var total: Int
    var slow: Int
    var frozen: Int
    var refreshRate: Double

    /// Milliseconds lost beyond the frame budget, summed over slow frames.
    var delayMs: Double

    /// The frame budget, 0 when the engine had none to report.
    var budgetMs: Double
    var reason: FrameSegmentReason
    var screenName: String
    var screenKey: String
}

/// What a tap or a gesture landed on, as the capture layer found it. The pipeline masks `label`,
/// `hint` and `valueText` when the privacy rules or `masked` say so.
struct InteractionTarget {
    /// The touched element's class (`UIButton`); empty for an element of SwiftUI's accessibility
    /// tree, which has none, and `Button` for a SwiftUI button named by its gesture.
    var component = ""

    /// The accessible name: the accessibility label, else the visible text.
    var label = ""
    var role = ""
    var hint = ""

    /// Accessibility flags (`selected`, `disabled`, …), each true when present.
    var state: [String: Any]?

    /// The accessibility value. Never a text field's, which is what the user typed.
    var valueText: String?

    /// The views from the outside in (`UIWindow > UIView > UIButton`).
    var componentPath = ""

    /// Marked private, itself or an ancestor.
    var masked = false
}

/// What kind of interaction: a tap, a gesture, or a finished text edit.
enum InteractionKind: String {
    case tap
    case longPress = "long_press"
    case swipe
    case scroll
    case pinch
    case input
}

/// Which way a swipe or scroll moved.
enum GestureDirection: String {
    case up, down, left, right
}

/// How a gesture other than a tap moved.
struct GestureMeasure {
    /// None for a long press or a pinch.
    var direction: GestureDirection?
    var distanceDp: Int
    var velocityDpS: Int
    var durationMs: Int
    var pointerCount: Int

    /// Cut short (the gesture was cancelled).
    var partial = false
}

/// A tap, a gesture or a finished text edit (`input`, which carries no coordinates and never the
/// text).
struct InteractionCapture {
    var kind: InteractionKind
    var target: InteractionTarget

    /// Points: where a tap lifted, or where a gesture started.
    var x: Double?
    var y: Double?

    /// For gestures only.
    var gesture: GestureMeasure?
    var timestampNs: Int64?
}
