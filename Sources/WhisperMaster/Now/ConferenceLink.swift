import Foundation

/// Finds the "join the call" link on a calendar event.
///
/// A meeting countdown that cannot be joined is a nag. The link is almost never in
/// a tidy field though: invitations put it in the location, in the URL, or buried
/// in a wall of dial-in numbers and legal boilerplate in the notes, so this reads
/// all three in that order of trust.
///
/// **It is an allowlist of hosts, not a first-URL-wins scan**, and that is the
/// whole design. Event notes routinely carry an unsubscribe link, a room-booking
/// link and a company wiki page; the first URL in a Google invitation is often the
/// calendar entry itself. Opening one of those when the user asked to join a call
/// is worse than showing no button, so an unrecognised host yields `nil`.
///
/// Pure and testable — nothing here touches EventKit.
enum ConferenceLink {
    /// Hosts known to answer a bare URL with a joinable call.
    ///
    /// Matched as a **suffix of the host**, so `eu01web.zoom.us` and
    /// `acme.zoom.us` both hit without `notzoom.us` doing so.
    static let hosts: [String] = [
        "zoom.us",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "meet.jit.si",
        "facetime.apple.com",
        "chime.aws",
        "gotomeeting.com",
        "bluejeans.com",
        "discord.gg",
        "slack.com",
    ]

    /// The first joinable link across `url`, `location` and `notes`, in that order.
    ///
    /// The explicit `url` field is trusted first because a client that filled it in
    /// meant it. `location` comes next: a one-line field is far likelier to hold
    /// the real link than a body that also lists three dial-in numbers.
    static func find(url: String? = nil,
                     location: String? = nil,
                     notes: String? = nil) -> URL? {
        for source in [url, location, notes] {
            guard let source, !source.isEmpty else { continue }
            if let found = firstJoinable(in: source) { return found }
        }
        return nil
    }

    /// The first allowlisted URL in a block of text.
    static func firstJoinable(in text: String) -> URL? {
        for candidate in urls(in: text) where isJoinable(candidate) {
            return candidate
        }
        return nil
    }

    /// Whether a URL points at a call we are willing to open on the user's behalf.
    static func isJoinable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }
        // A bare host with no path is a marketing page, not a room. The one
        // exception would be a vanity domain, which we cannot tell apart anyway.
        guard url.path.count > 1 else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Every URL in a block of text, in order.
    ///
    /// `NSDataDetector` rather than a regex: invitation bodies wrap links across
    /// lines, trail them with punctuation, and quote them inside angle brackets,
    /// and the detector already knows all three.
    static func urls(in text: String) -> [URL] {
        guard let detector = detector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}
