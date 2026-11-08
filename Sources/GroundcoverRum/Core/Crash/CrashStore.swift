/// The native engine's crash records, and the session it files with a crash. The pipeline keeps
/// that session current and delivers the records.
protocol CrashStore: AnyObject {
    /// The session envelope plus the current screen, as JSON, for the engine to file with a
    /// crash; nil clears it.
    func updateSessionSnapshot(_ json: String?)

    /// The previous runs' crash records, as a JSON array.
    func pendingCrashReportsJson() -> String

    /// Deletes the records with these ids, once their batch was delivered.
    func clearPendingCrashReports(ids: [String])
}
