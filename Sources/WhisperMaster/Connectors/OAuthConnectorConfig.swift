import Foundation

/// The configuration seam for the OAuth-backed connectors (Gmail, Slack, and the
/// mail side of Outlook). These need an OAuth app registered with each provider;
/// the **client id is client-safe** and read from `Info.plist` (env override for
/// dev), mirroring how `ClerkConfig` reads its publishable key.
///
/// ⚠️ Until real ids are dropped in, `isConfigured(_:)` returns `false` and the
/// connector shows a "needs setup" state instead of a Connect button — the app
/// never pretends an unconfigured OAuth connector can fetch data. Registering the
/// apps and obtaining tokens (a full OAuth + token-exchange flow, typically via a
/// small backend to hold the client secret) is the remaining work to make these
/// connectors live; the architecture here is the place to wire it.
enum OAuthConnectorConfig {
    /// Client id for a provider, if configured. Reads env first (dev), then the
    /// `Info.plist` key `Connector<Provider>ClientID` (e.g. `ConnectorGmailClientID`).
    static func clientID(for kind: ConnectorKind) -> String? {
        guard kind.auth == .oauth else { return nil }
        let provider = plistProviderName(for: kind)
        if let env = ProcessInfo.processInfo.environment["CONNECTOR_\(provider.uppercased())_CLIENT_ID"],
           !isPlaceholder(env) {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "Connector\(provider)ClientID") as? String,
           !isPlaceholder(plist) {
            return plist
        }
        return nil
    }

    /// Whether this OAuth connector has usable credentials configured.
    static func isConfigured(_ kind: ConnectorKind) -> Bool {
        kind.auth == .oauth ? clientID(for: kind) != nil : true
    }

    private static func plistProviderName(for kind: ConnectorKind) -> String {
        switch kind {
        case .gmail: return "Gmail"
        case .slack: return "Slack"
        case .outlook: return "Outlook"
        case .notion: return "Notion"
        case .linear: return "Linear"
        case .googleDrive: return "GoogleDrive"
        case .github: return "GitHub"
        case .zoom: return "Zoom"
        case .asana: return "Asana"
        default: return kind.rawValue
        }
    }

    /// Treat empty / obvious template values as "not set".
    private static func isPlaceholder(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return true }
        let lower = v.lowercased()
        return lower.contains("your_") || lower.contains("placeholder") || lower.hasPrefix("<")
    }
}
