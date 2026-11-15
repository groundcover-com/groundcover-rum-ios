import Foundation
// The module's name depends on how KSCrash was installed. Its podspec compiles
// every subspec into a SINGLE pod target with DEFINES_MODULE, so a CocoaPods
// install (RN, and Flutter apps on CocoaPods) exposes exactly one Clang module,
// named after the root pod: `KSCrash`. Its Swift package makes each feature its
// own target, so a SwiftPM install (the Flutter plugin's default) names this one
// `KSCrashRecording`. Either way we depend on the Recording part alone — that
// governs which sources are compiled in, not what the module is called.
#if canImport(KSCrashRecording)
import KSCrashRecording
#else
import KSCrash
#endif

/// Installs KSCrash and turns its reports into our pending records. Only the `Recording`
/// subspec is used — its Installations/Sinks/Filters exist to POST to a vendor endpoint
/// in its own format, and we already have a wire format and transport that JS owns.
///
/// Nothing here runs in the crash path: KSCrash writes from its async-signal-safe
/// handler, and this only reads what it left behind, on the next launch.
final class GCRumCrashReporter {
    private let store: GCRumSessionSnapshotStore

    /// Whether THIS SDK installed the process-wide KSCrash singleton. Static because
    /// KSCrash is: a reporter is built per React instance, RN rebuilds those, and KSCrash
    /// deliberately stays installed across them — so a second reporter meets a singleton
    /// already recording, is told `AlreadyInstalled`, and would report `crashes: false` for
    /// capture that is running.
    ///
    /// A flag rather than a catch on the error, because "installed by us" and "installed
    /// by someone else" must differ: when another KSCrash-based reporter owns the singleton,
    /// [harvest] DELETES the reports it reads, so harvesting a store we do not own would
    /// destroy another SDK's crashes. Crash reporters that are not KSCrash-based install their
    /// own handlers and chain to ours.
    private static var installedBySDK = false

    init(store: GCRumSessionSnapshotStore) {
        self.store = store
    }

    func install() throws {
        // Already ours and already recording, so this is success rather than a
        // no-op: the caller goes on to harvest and to report crashes as armed,
        // which is what is actually true.
        guard !GCRumCrashReporter.installedBySDK else { return }

        try KSCrash.shared.install(with: GCRumCrashReporter.configuration())
        GCRumCrashReporter.installedBySDK = true
    }

    /// What the SDK asks of KSCrash. Its own function so a test can read it.
    static func configuration() -> KSCrashConfiguration {
        let config = KSCrashConfiguration()
        config.monitors = [
            .machException,
            .signal,
            .cppException,
            .nsException,
        ]
        // Note the two we deliberately leave out: the deadlock monitor (our hang
        // watchdog covers main-thread stalls without killing the app to report
        // one) and user-reported (JavaScript owns handled errors).
        //
        // A disk cap independent of JS: if the app never reaches a working
        // network, reports must not accumulate forever.
        config.reportStoreConfiguration.maxReportCount = 10
        // KSCrash's default rebinds __cxa_throw in every loaded image to record where a C++
        // exception was thrown. That reaches into code that throws and catches its own
        // exceptions, and can break apps that do. From KSCrash 2.6 a C++ crash still records
        // where it was thrown: KSCrash works it out at terminate, into last_exception_backtrace,
        // which the mapper reads. Below 2.6, which the version ranges still allow, a throw from
        // another image can leave the crash's stack empty or stale.
        config.enableSwapCxaThrow = false
        return config
    }

    /// Reads the reports KSCrash persisted for previous runs, pairs each with the
    /// session snapshot that run left behind, and stages them as pending records.
    ///
    /// MUST run before the current run's snapshot overwrites the stored one —
    /// otherwise last run's fatal is attributed to this run's session.
    func harvest(previousRunSnapshot: String?) {
        guard let reportStore = KSCrash.shared.reportStore else { return }

        for reportId in reportStore.reportIDs {
            guard let report = reportStore.report(for: reportId.int64Value)?.value else { continue }

            if let json = GCRumCrashReportMapper.buildRecord(
                report: report,
                sessionSnapshotJson: previousRunSnapshot
            ),
               let id = recordId(of: json) {
                store.writePendingRecord(id: id, json: json)
            }

            // KSCrash's copy has been transcribed into a self-contained record;
            // keeping it would re-harvest the same crash on every launch.
            reportStore.deleteReport(with: reportId.int64Value)
        }
    }

    private func recordId(of json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed["id"] as? String
    }
}
