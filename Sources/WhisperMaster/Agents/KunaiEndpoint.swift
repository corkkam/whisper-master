import Foundation

/// Where kunai is, and whether it is there at all.
///
/// The notch is a **client**, not a host: it never starts, installs or supervises
/// kunai. If a server answers the surface lights up; if not, the feature is simply
/// absent. That is what keeps this a dictation app that can also drive an agent,
/// rather than a dictation app that ships an agent server.
///
/// **Loopback first, then the file kunai writes.** A tailnet install binds *both*
/// `127.0.0.1:<port>` in plain HTTP and the tailnet IP with TLS — verified with
/// `lsof` against a real install — and this app always runs on the same machine as
/// the server it is talking to. So the local address is the right one: no TLS
/// handshake, no MagicDNS resolution, and it keeps working when Tailscale is down or
/// the Mac is offline. Reading `<dataDir>/url` (the file kunai records its own public
/// URL in on every boot, and the one its `/kunai` slash command reads) stays in the
/// list underneath, because a non-default `-addr`, a moved port, or a
/// loopback-less bind is exactly what it exists to describe. The caller probes in
/// order, so the first address that actually answers wins either way.
///
/// No credentials appear anywhere in this client, and that is a property of the two
/// perimeters kunai supports rather than an oversight. Loopback is never locked (a
/// forgotten PIN has to stay fixable from the machine itself), and on a tailnet the
/// tailnet *is* the auth perimeter. The one listener that does carry a PIN is
/// `-lan`, which is off by default; a client pointed at one of those gets a 401 and
/// the surface stays dark, which is the honest outcome.
struct KunaiEndpoint: Sendable, Equatable {

    /// kunai's own default bind (`-addr`, `KUNAI_ADDR`).
    static let defaultPort = 8443

    /// Scheme, host and port of the server. Kept whole rather than split, because a
    /// tailnet install is `https` and a local one is `http`, and reassembling that
    /// from parts is how the scheme gets lost.
    var baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    init(host: String = "127.0.0.1", port: Int = KunaiEndpoint.defaultPort, secure: Bool = false) {
        self.baseURL =
            URL(string: "\(secure ? "https" : "http")://\(host):\(port)")
            ?? URL(fileURLWithPath: "/")
    }

    /// Data directories kunai installs into, newest channel first, each with the
    /// port `install.sh` gives that channel — the nightly gets its own directory
    /// *and* its own port so it can run beside a stable install without sharing
    /// anything.
    static let channels: [(directory: String, port: Int)] = [
        (".kunai", defaultPort), (".kunai-nightly", defaultPort + 1),
    ]

    static var dataDirectories: [String] { channels.map(\.directory) }

    /// Where to look, in order: an explicit override, then whatever each installed
    /// kunai recorded for itself, then the documented default.
    static var resolved: KunaiEndpoint { candidates.first ?? KunaiEndpoint() }

    /// Every endpoint worth trying. More than one can exist on a machine running
    /// both channels, and the caller probes them in order rather than assuming.
    static var candidates: [KunaiEndpoint] {
        var found: [KunaiEndpoint] = []

        if let raw = ProcessInfo.processInfo.environment["KUNAI_URL"],
           let url = normalized(raw) {
            found.append(KunaiEndpoint(baseURL: url))
        }

        // Loopback next, one per installed channel. Both processes are on this Mac,
        // so this is the cheapest and most reliable address there is — and unlike the
        // recorded URL it does not depend on Tailscale being up.
        for channel in channels {
            found.append(KunaiEndpoint(port: channel.port))
        }

        // Then whatever each install recorded for itself, which is what covers a
        // non-default bind.
        let home = FileManager.default.homeDirectoryForCurrentUser
        for channel in channels {
            let path = home.appendingPathComponent(channel.directory)
                .appendingPathComponent("url")
            guard let contents = try? String(contentsOf: path, encoding: .utf8),
                  let url = normalized(contents)
            else { continue }
            found.append(KunaiEndpoint(baseURL: url))
        }

        // Preserve order while dropping duplicates: a machine with one install must
        // not probe the same address twice.
        var seen = Set<String>()
        return found.filter { seen.insert($0.baseURL.absoluteString).inserted }
    }

    /// Trim, parse, and reject anything that is not an absolute http(s) URL. The
    /// file kunai writes ends in a newline, which `URL` would otherwise carry into
    /// the host.
    static func normalized(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    func api(_ path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// The event socket for one session. `since` is the resume mark: kunai keeps a
    /// per-session ring buffer, so reattaching asks for everything after the last
    /// sequence seen instead of replaying the conversation.
    ///
    /// The scheme follows the base URL — a TLS install needs `wss`, and asking for
    /// `ws` there fails the upgrade rather than silently downgrading.
    func socket(sessionID: String, since: UInt64) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("ws/app/\(sessionID)"),
            resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        if since > 0 { components.queryItems = [URLQueryItem(name: "since", value: String(since))] }
        return components.url
    }
}
