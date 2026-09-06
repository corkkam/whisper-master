import Foundation

/// A machine in the kunai fleet, as `GET /api/machines` reports it.
///
/// **Sessions are per machine, and so is the fleet socket.** kunai's own note on
/// `handleFleetWS` says it plainly — "the fleet socket: one per machine" — and its web
/// app opens one against each machine's own origin (which is why that handler's origin
/// policy allows a peer's). `GET /api/sessions` and the fleet push both come from the
/// local session manager, so a client that talks only to the Mac it runs on sees only
/// the Mac it runs on, however many machines are registered.
struct KunaiMachine: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    /// The human name — a hostname, usually. What the notch shows beside a session
    /// that is not on this Mac.
    var label: String
    /// Where that machine's kunai answers. On a tailnet this is its MagicDNS name
    /// with TLS, so the socket scheme has to follow it.
    var url: String
    /// Whether this is the machine we are running on. The local one is reached
    /// through ordinary discovery (loopback first) rather than its advertised URL,
    /// which is both faster and survives Tailscale being down.
    var isSelf: Bool

    enum CodingKeys: String, CodingKey {
        case id, label, url
        case isSelf = "self"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
    }

    init(id: String, label: String, url: String, isSelf: Bool) {
        self.id = id
        self.label = label
        self.url = url
        self.isSelf = isSelf
    }

    /// The endpoint to reach this machine on, given whatever discovery settled on for
    /// the local one. A remote machine has only its advertised URL; the local machine
    /// prefers the discovered endpoint, because loopback beats a round trip through
    /// the tailnet to reach ourselves.
    func endpoint(local: KunaiEndpoint?) -> KunaiEndpoint? {
        if isSelf, let local { return local }
        guard let parsed = KunaiEndpoint.normalized(url) else { return nil }
        return KunaiEndpoint(baseURL: parsed)
    }

    /// A short name for the band. Trailing `.local` is noise on a bezel, and the
    /// hostname is usually already the machine's name without it.
    var shortLabel: String {
        let name = label.isEmpty ? id : label
        guard let dot = name.firstIndex(of: "."), name.hasSuffix(".local") else { return name }
        return String(name[..<dot])
    }
}
