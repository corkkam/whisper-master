import Foundation

/// Which apps count as "a call is happening" when they hold the microphone, and
/// what to call them on the notch.
///
/// **An allowlist, never "any app using the mic".** Voice memos, a browser
/// dictation box and our own dictation all open the mic too; offering to take
/// meeting notes for those is noise. A browser is only a meeting when one of its
/// window titles names a meeting service (`BrowserMeetingProbe`), which is why
/// browsers are listed separately.
enum MeetingAppCatalog {
    /// Native meeting apps by bundle id. Matched by prefix, because Core Audio
    /// often reports a helper (`us.zoom.xos.ZoomAudioDevice`, `…Helper`) rather
    /// than the app itself.
    static let nativeApps: [(bundlePrefix: String, name: String)] = [
        ("com.tinyspeck.slackmacgap", "Slack huddle"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("us.zoom.xos", "Zoom"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.webex.meetingmanager", "Webex"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp call"),
        ("ru.keepcoder.Telegram", "Telegram call"),
    ]

    /// Browsers whose tabs may hold a web meeting. Chrome-family browsers render
    /// audio from helper processes (`com.google.Chrome.helper`), so this is a
    /// prefix match too.
    static let browsers: [String] = [
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "com.apple.WebKit",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    /// Window-title fragments that mark a web meeting, with the name to show.
    /// Checked case-insensitively against every window title of a browser that
    /// holds the mic.
    static let webMeetingTitles: [(fragment: String, name: String)] = [
        ("meet.google.com", "Google Meet"),
        ("Meet - ", "Google Meet"),
        ("Google Meet", "Google Meet"),
        ("Microsoft Teams", "Microsoft Teams"),
        ("Zoom Meeting", "Zoom"),
        ("Zoom Workplace", "Zoom"),
        ("Webex", "Webex"),
        ("Whereby", "Whereby"),
        ("Jitsi Meet", "Jitsi Meet"),
        ("Huddle", "Slack huddle"),
        ("Discord", "Discord"),
    ]

    /// The display name for a native meeting app, or nil when the bundle is not one.
    static func nativeName(for bundleID: String) -> String? {
        nativeApps.first { bundleID.hasPrefix($0.bundlePrefix) }?.name
    }

    /// The prefix that identifies this app's family, used to find every process
    /// to tap for its audio.
    static func family(of bundleID: String) -> String? {
        if let native = nativeApps.first(where: { bundleID.hasPrefix($0.bundlePrefix) }) {
            return native.bundlePrefix
        }
        return browsers.first { bundleID.hasPrefix($0) }
    }

    static func isBrowser(_ bundleID: String) -> Bool {
        browsers.contains { bundleID.hasPrefix($0) }
    }

    /// The meeting service a browser window title names, or nil.
    static func webMeetingName(inTitle title: String) -> String? {
        webMeetingTitles.first {
            title.range(of: $0.fragment, options: .caseInsensitive) != nil
        }?.name
    }
}
