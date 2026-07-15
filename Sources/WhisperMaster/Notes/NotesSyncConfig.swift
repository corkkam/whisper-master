import Foundation

/// Where notes & reminders sync to. The dashboard (`eval/dashboard`) exposes
/// `POST`/`GET /api/notes`; this resolves that URL and the optional shared-secret
/// fallback token. Overridable via Info.plist / env for dev without a rebuild.
/// Mirrors `UsageSyncConfig`.
enum NotesSyncConfig {
    private static var baseURLString: String {
        (Bundle.main.object(forInfoDictionaryKey: "UsageSyncBaseURL") as? String)
            ?? ProcessInfo.processInfo.environment["USAGE_SYNC_BASE_URL"]
            ?? "https://whisper-eval-dashboard.vercel.app"
    }

    /// The `/api/notes` endpoint, or nil if the base URL is malformed.
    static var endpoint: URL? {
        guard let base = URL(string: baseURLString) else { return nil }
        return base.appendingPathComponent("api").appendingPathComponent("notes")
    }

    /// Shared-secret fallback matching the dashboard's ingest gate — used only
    /// when the server isn't verifying Clerk session JWTs. The real attribution
    /// is the verified Bearer token. Same value as usage sync.
    static var ingestToken: String? {
        ProcessInfo.processInfo.environment["INGEST_TOKEN"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "UsageIngestToken") as? String)
    }
}
