/// What the host gives the pipeline. Everything platform-shaped comes in here, so the core runs on
/// fakes in tests.
struct PlatformServices {
    var storage: PlatformStorage
    var clock: RumClock
    var sender: BatchSender

    /// The session envelope's device part: `source`, `os`, `device`, `app`.
    var deviceAttributes: () throws -> [String: Any]

    var executor: CoreExecutor

    /// The native engine's crash store.
    var crashStore: CrashStore?

    /// The native engine, which the pipeline starts once its own start has decided the session.
    var engine: NativeEngine?
}

/// What capture hands the pipeline.
enum Capture {
    case custom(CustomEventCapture)
    case log(LogCapture)
    case error(ErrorCapture)
    case network(NetworkCapture)
    case interaction(InteractionCapture)
    case navigation(NavigationCapture)
    case hang(HangCapture)
    case appStart(AppStartCapture)
    case frameSegment(FrameSegmentCapture)
}

/// How ``CorePipeline/start(_:platform:)`` ended.
enum PipelineStart {
    /// The session is recorded: capture can be armed.
    case recording

    /// The sampling verdict left this session out. Nothing is recorded, every later call is a
    /// no-op, and capture stays unarmed.
    case unsampled
}

/// The host's foreground state, as the pipeline needs it.
enum HostLifecycle {
    /// Back in the foreground: a presence signal.
    case foreground

    /// Transitioning (a call, the app switcher): activity is persisted.
    case inactive

    /// In the background: activity is persisted and the buffer is sent.
    case background
}
