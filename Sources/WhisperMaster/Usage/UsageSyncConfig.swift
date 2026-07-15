import Foundation

/// Where usage rollups sync to. The dashboard (`eval/dashboard`) exposes
/// `POST /api/usage`; this resolves that URL and the optional shared-secret
/// fallback token. Overridable via Info.plist / env for dev without a rebuild.
enum UsageSyncConfig {
    /// Base dashboard origin. Defaults to the deployed public dashboard.
    private static var baseURLString: String {
        (Bundle.main.object(forInfoDictionaryKey: "UsageSyncBaseURL") as? String)
            ?? ProcessInfo.processInfo.environment["USAGE_SYNC_BASE_URL"]
            ?? "https://whisper-eval-dashboard.vercel.app"
    }

    /// The `/api/usage` upsert endpoint, or nil if the base URL is malformed.
    static var endpoint: URL? {
        guard let base = URL(string: baseURLString) else { return nil }
        return base.appendingPathComponent("api").appendingPathComponent("usage")
    }

    /// Shared-secret fallback matching the dashboard's `/api/ingest` gate — used
    /// only when the server isn't verifying Clerk session JWTs. Not truly secret
    /// in a distributed app; the real attribution is the verified Bearer token.
    static var ingestToken: String? {
        ProcessInfo.processInfo.environment["INGEST_TOKEN"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "UsageIngestToken") as? String)
    }
}
