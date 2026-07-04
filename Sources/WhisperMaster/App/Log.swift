import OSLog

/// Centralized `os.Logger` instances for the app.
///
/// Use `.notice` (or higher) for anything we want to be able to diagnose after
/// the fact: macOS persists `.notice`/`.error`/`.fault` to the unified log,
/// while `.debug`/`.info` are memory-only and vanish. So a model-prep fallback
/// logged at `.error` is recoverable later via:
///   `log show --predicate 'subsystem == "app.whispermaster.mac"' --last 1d`
enum Log {
    private static let subsystem = "app.whispermaster.mac"

    /// Model download / install / load pipeline (R2 mirror, unzip, FluidAudio).
    static let modelPrep = Logger(subsystem: subsystem, category: "model-prep")

    /// On-device text formatting (spoken → written form) via Apple's model.
    static let formatter = Logger(subsystem: subsystem, category: "formatter")

    /// Streaming transcription lifecycle — final decode, recovery fallbacks.
    static let transcription = Logger(subsystem: subsystem, category: "transcription")

    /// Anonymous, opt-in usage analytics (TelemetryDeck) — configuration and gating.
    static let analytics = Logger(subsystem: subsystem, category: "analytics")
}
