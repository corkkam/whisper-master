import Foundation

// MARK: - TailscaleEndpoint

/// This Mac's reachable Tailscale address. Shown as text (and a QR code) in
/// Settings so the phone can pair without typing.
struct TailscaleEndpoint: Equatable {
    let host: String
    let port: UInt16

    /// Compact display, e.g. `mac.tailnet.ts.net:47823`.
    var display: String { "\(host):\(port)" }

    /// Payload encoded in the pairing QR code and parsed by the iOS scanner. Uses
    /// the app's `whispermaster` URL scheme so it's unambiguous and extensible.
    var pairingURL: String {
        var components = URLComponents()
        components.scheme = "whispermaster"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
        ]
        return components.string ?? "whispermaster://pair?host=\(host)&port=\(port)"
    }
}

// MARK: - TailscaleStatus

/// Distinguishes the three states the Settings UI must show differently, so a
/// user without Tailscale gets a helpful prompt instead of a silently missing
/// card.
enum TailscaleStatus: Equatable {
    /// Tailscale is up and we resolved this Mac's address.
    case available(TailscaleEndpoint)
    /// The CLI is present but Tailscale is stopped / signed out.
    case notConnected
    /// The `tailscale` CLI isn't installed (or it's a GUI-only install with no CLI).
    case notInstalled
}

// MARK: - TailscaleAddress
//
// Best-effort, READ-ONLY lookup of this Mac's own Tailscale status/address so the
// Settings UI can show a pairing QR (or the right prompt). It shells out to the
// `tailscale` CLI purely to *read* status — it never changes any Tailscale state.

enum TailscaleAddress {
    static func current() async -> TailscaleStatus {
        await Task.detached(priority: .utility) { resolve() }.value
    }

    /// Common install locations for the CLI (open-source pkg, Homebrew, and the
    /// symlink the macOS app creates when the user enables the CLI).
    private static let candidatePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    private static func resolve() -> TailscaleStatus {
        guard let cli = candidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            return .notInstalled
        }

        guard let json = run(cli, ["status", "--json"]),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            // CLI present but status unreadable → treat as not connected.
            return .notConnected
        }

        // Only trust an address when the backend is actually up; a stopped/
        // signed-out daemon still reports a cached DNS name we shouldn't advertise.
        guard (root["BackendState"] as? String) == "Running" else { return .notConnected }

        let port = WireProtocol.fixedPort
        let selfPeer = root["Self"] as? [String: Any]

        if let dns = selfPeer?["DNSName"] as? String, !dns.isEmpty {
            let host = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
            return .available(TailscaleEndpoint(host: host, port: port))
        }
        // Running but MagicDNS off → fall back to the tailnet IPv4.
        if let ips = selfPeer?["TailscaleIPs"] as? [String],
           let ipv4 = ips.first(where: { !$0.contains(":") }) {
            return .available(TailscaleEndpoint(host: ipv4, port: port))
        }
        return .notConnected
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // Read before waiting so a large payload can't deadlock the pipe.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
