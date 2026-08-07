import Foundation

/// Detects that the previous run ended badly and reports it once, on the next
/// launch.
///
/// **Why next-launch detection rather than an in-process handler.** The crashes
/// this app actually suffers are the ones a handler can't catch: an Objective-C
/// exception out of `AVAudioEngine` is an `abort()`, and the MLX/Metal fault
/// seen in the field (`EXC_BAD_ACCESS` inside `AGXMetalG17G`) kills the process
/// in kernel code. `NSSetUncaughtExceptionHandler` sees neither, and a signal
/// handler that tries to allocate or send a network request during a SIGSEGV is
/// a second crash waiting to happen. The OS has already written a full report by
/// the time we're next launched — reading *that* is both safer and strictly more
/// informative.
///
/// **The two-signal design.** A `UserDefaults` sentinel says *whether* the last
/// run exited cleanly; the `.ips` report says *what happened*. They're reported
/// together because neither is sufficient alone: the sentinel can't tell a crash
/// from a Force Quit or a power cut, and the report directory may be unreadable.
/// `hasReport` travels with the event so a GA report can separate the confident
/// crashes from the merely-unclean exits instead of conflating them into one
/// inflated crash rate.
///
/// Nothing here bypasses the opt-in: every send goes through `Analytics.send`,
/// which is gated on the user's preference and on `RegulatedMode`.
enum CrashReporter {
    private static let cleanExitKey = "WhisperMaster.cleanExit.v1"
    private static let lastIncidentKey = "WhisperMaster.lastCrashIncident.v1"

    // MARK: - Sentinel

    /// Record that this launch is underway. Must run early — anything that
    /// crashes before this leaves the previous run's verdict standing.
    static func markLaunch() {
        UserDefaults.standard.set(false, forKey: cleanExitKey)
    }

    /// Record a deliberate quit. Called from `applicationWillTerminate`, which
    /// macOS invokes for ⌘Q, the tray Quit item, and logout — but *not* for a
    /// crash or a Force Quit, which is exactly the discrimination this relies on.
    static func markCleanExit() {
        UserDefaults.standard.set(true, forKey: cleanExitKey)
    }

    /// Whether the previous run failed to reach `markCleanExit`.
    ///
    /// A first-ever launch has no key at all; that defaults to `true` (clean) so
    /// a fresh install never reports a crash it didn't have.
    private static var previousRunEndedUncleanly: Bool {
        guard let recorded = UserDefaults.standard.object(forKey: cleanExitKey) as? Bool else {
            return false
        }
        return !recorded
    }

    // MARK: - Reporting

    /// Look for evidence of a crash in the previous run and report it once.
    ///
    /// Runs off the main actor: it stats and reads a directory of files, which is
    /// disk I/O in the launch path and has no business blocking the first frame.
    /// Call it *after* `markLaunch()`, which reads the sentinel this consumes.
    @MainActor
    static func reportPreviousCrashIfNeeded() {
        guard previousRunEndedUncleanly else { return }
        // Consume the sentinel immediately. If the scan below crashes, or the app
        // is quit before it finishes, the same unclean exit must not be reported
        // again on the launch after that.
        markCleanExit()

        let bundleID = Bundle.main.bundleIdentifier
        let alreadyReported = UserDefaults.standard.string(forKey: lastIncidentKey)

        Task.detached(priority: .utility) {
            let report = findLatestCrashReport(bundleID: bundleID, excludingIncident: alreadyReported)

            await MainActor.run {
                if let report {
                    if !report.incidentID.isEmpty {
                        UserDefaults.standard.set(report.incidentID, forKey: lastIncidentKey)
                    }
                    Log.analytics.error(
                        """
                        Previous run crashed: \(report.exceptionType, privacy: .public) \
                        \(report.signal, privacy: .public) in \
                        \(report.signature, privacy: .public) (v\(report.crashedVersion, privacy: .public))
                        """
                    )
                } else {
                    Log.analytics.notice("Previous run exited uncleanly; no matching crash report found.")
                }
                Analytics.shared.send(.appCrashed(report))
            }
        }
    }

    // MARK: - Report discovery

    /// The newest crash report belonging to this app, or `nil`.
    ///
    /// Reading `~/Library/Logs/DiagnosticReports/` can fail outright — the app is
    /// un-sandboxed so it normally succeeds, but a managed Mac or a stricter
    /// future macOS may refuse. That's a `nil`, not an error: the caller still
    /// reports the unclean exit, just without detail.
    static func findLatestCrashReport(
        bundleID: String?,
        excludingIncident: String?,
        directory: URL? = nil,
        now: Date = Date()
    ) -> CrashReport? {
        let reportsDirectory = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return nil }

        // Two cheap filters before any file is opened. The directory holds every
        // diagnostic the OS has written — hangs, wakeup reports, other apps —
        // and the crash we want is minutes old, so both prefix and age rule out
        // nearly everything without a read.
        let candidates = entries
            .filter { $0.pathExtension == "ips" }
            .filter { $0.lastPathComponent.hasPrefix("WhisperMaster") }
            .compactMap { url -> (URL, Date)? in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, now.timeIntervalSince(modified) <= maxReportAge else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }

        for (url, _) in candidates {
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let report = CrashReportParser.parse(raw, expectingBundleID: bundleID)
            else { continue }
            // Same crash, already sent. Everything older is older still, so stop.
            if let excludingIncident, report.incidentID == excludingIncident { return nil }
            return report
        }
        return nil
    }

    /// How far back a report can be and still plausibly belong to the run that
    /// just ended. Generous — a crash during a long-running dictation session may
    /// predate the relaunch by a while — but bounded, so a machine that was off
    /// for a week doesn't attribute last week's crash to this morning's launch.
    private static let maxReportAge: TimeInterval = 24 * 60 * 60
}
