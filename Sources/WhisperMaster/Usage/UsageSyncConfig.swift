import Foundation

/// Where usage rollups sync to. The web app at whisper.corkkam.com exposes
/// `POST /api/usage`; this resolves that URL and the optional shared-secret
/// fallback token. Overridable via Info.plist / env for dev without a rebuild.
///
/// This used to point at a separate SvelteKit deploy
/// (`whisper-eval-dashboard.vercel.app`), which is why that project could not be
/// deleted: every shipped build hardcoded it. The routes moved to the landing
/// site, so builds from here on talk to the site itself. **The old deploy still
/// has to stay up** until 1.1.0-beta.7 and .8 have aged out in the field, since
/// those builds have this string compiled into them.
enum UsageSyncConfig {
    /// Base origin for sync. Defaults to the production site.
    private static var baseURLString: String {
        (Bundle.main.object(forInfoDictionaryKey: "UsageSyncBaseURL") as? String)
            ?? ProcessInfo.processInfo.environment["USAGE_SYNC_BASE_URL"]
            ?? "https://whisper.corkkam.com"
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
