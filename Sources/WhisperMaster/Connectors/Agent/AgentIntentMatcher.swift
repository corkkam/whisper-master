import Foundation

/// What a spoken assistant capture asked of this Mac, when it says so in a fixed form.
enum AgentIntent: Equatable, Sendable {
    case openApp(InstalledApp)
    case openURL(URL)
}

/// Reads "open Figma" and "go to github.com" out of a spoken assistant capture, with
/// no model.
///
/// **⚠️ This is legal only downstream of the assistant chord**, in
/// `routeCommandCapture`, for the reason `MediaCommandDetector` is: that path has
/// already suppressed the paste. Run over an ordinary dictation, "open the file and
/// check the numbers" would be eaten as a command. Do not call it from anywhere else.
///
/// The **whole** capture must be one template, and every slot is closed: an app this
/// Mac really has, or a bare domain. "Open Figma and share it with Sam" is not a
/// template, so it goes to the agent. An app opens at once, because the user's own
/// exact words are the consent, as they are for "pause the music". A domain still
/// goes to the card, because a link is shown on the card every time.
enum AgentIntentMatcher {
    private static let appVerbs = ["open", "launch", "switch to", "go to"]
    private static let siteVerbs = ["open", "go to"]
    /// Labels of letters, digits and inner hyphens, then a letters-only top level.
    /// No scheme, path, query, port, user or IP address can fill it.
    private static let domain = #"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}$"#

    static func match(_ text: String,
                      installedApp: (String) -> InstalledApp? = InstalledApps.find) -> AgentIntent? {
        if let slot = slot(after: appVerbs, in: InstalledApps.normalized(text)) {
            let name = appName(slot)
            if !name.isEmpty, let app = installedApp(name) { return .openApp(app) }
        }
        return site(text).map(AgentIntent.openURL)
    }

    /// What follows one of `verbs` at the start of `words`, after an optional "please".
    private static func slot(after verbs: [String], in words: String) -> String? {
        var words = words
        if words.hasPrefix("please ") { words.removeFirst("please ".count) }
        guard let verb = verbs.first(where: { words.hasPrefix($0 + " ") }) else { return nil }
        return String(words.dropFirst(verb.count + 1))
    }

    /// "the calendar app" names Calendar.
    private static func appName(_ slot: String) -> String {
        var name = slot
        if name.hasPrefix("the ") { name.removeFirst("the ".count) }
        for suffix in [" application", " app"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    /// The domain a "go to …" capture names, as an https link. The dots survive here,
    /// unlike in the app slot, and "dot" is read as one.
    private static func site(_ text: String) -> URL? {
        var phrase = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // The formatter's closing full stop.
        while let last = phrase.last, ".!?,".contains(last) { phrase.removeLast() }
        phrase = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let slot = slot(after: siteVerbs, in: phrase) else { return nil }
        let host = slot.replacingOccurrences(of: " dot ", with: ".")
        guard host.range(of: domain, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + host)
    }
}
