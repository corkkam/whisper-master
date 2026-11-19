import AppKit
import ApplicationServices

/// The text the user had selected in the front app when they held the assistant
/// chord, so "summarize this" has a "this".
///
/// The model never sees it in its prompt — only `promptLine`, which names the app and
/// the length. It pulls the text with `read_selection`, and that read taints the run,
/// because a selection is often someone else's words: a web page, an email.
struct SelectionContext: Equatable, Sendable {
    let appName: String
    /// Shown to the model inside the tool result only, never in the prompt: a web
    /// page sets it, so it is not the user's own words either.
    let windowTitle: String?
    /// At most `SelectionReader.limit` characters.
    let text: String
    /// True when `text` is a cut of a longer selection.
    let wasCut: Bool
    /// The selection's length before any cut.
    let originalLength: Int

    /// The one line of context the prompt carries.
    var promptLine: String {
        "The user is in \(Self.promptSafe(appName)). They selected \(originalLength) characters. "
            + "Call read_selection to read them."
    }

    /// What `read_selection` hands the model.
    var toolText: String {
        // A page sets its own title, so it is clamped like the app name: an unbounded
        // title is resent on every later turn.
        let window = windowTitle.map { " — \u{201C}\(Self.promptSafe($0, limit: 120))\u{201D}" } ?? ""
        let cut = wasCut ? "\n[\(originalLength - text.count) more characters not shown]" : ""
        return "Selected in \(appName)\(window) (\(originalLength) characters):\n\(text)\(cut)"
    }

    /// What the trace keeps in place of the tool result: how much was read, never what.
    var traceLine: String {
        let cut = wasCut ? ", cut from \(originalLength)" : ""
        return "Read \(text.count) selected characters from \(appName)\(cut)."
    }

    /// The shortest run of the selection that counts as repeating it. A shorter run is
    /// a common phrase, and matching it would blank ordinary arguments.
    static let repeatRun = 40
    /// A selection shorter than `repeatRun` is matched whole, once it is this long: a
    /// 20-character key or PIN is exactly what a short selection tends to be, while
    /// anything shorter is too likely to be an ordinary word.
    static let wholeSelectionMinimum = 12

    /// `other` as a trace or the answer log may keep it: unchanged, or a placeholder
    /// when it repeats `repeatRun` characters of the selection in a row. A model that
    /// copies the selection into a note or an answer would otherwise persist it.
    func storable(_ other: String) -> String {
        repeats(in: other) ? "[selection, \(other.count) characters]" : other
    }

    /// Scalars, not characters: hashing 8,000 windows of `Character` is slow enough to
    /// feel on the main actor, and the threshold does not need grapheme precision.
    private func repeats(in other: String) -> Bool {
        if text.count < Self.repeatRun {
            return text.count >= Self.wholeSelectionMinimum && other.contains(text)
        }
        let run = Self.repeatRun
        let mine = Array(text.unicodeScalars), theirs = Array(other.unicodeScalars)
        guard mine.count >= run, theirs.count >= run else { return false }
        let windows = Set((0...mine.count - run).map { mine[$0 ..< $0 + run] })
        return (0...theirs.count - run).contains { windows.contains(theirs[$0 ..< $0 + run]) }
    }

    /// An app name is the app's own, but it still goes into a system prompt: one line,
    /// and short.
    private static func promptSafe(_ name: String, limit: Int = 60) -> String {
        let line = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "another app" : String(line.prefix(limit))
    }
}

/// Reads the front app's selected text through Accessibility.
///
/// **Every read is a blocking call into another process**, so it runs off the main
/// actor (`SelectionCapture`) with a short messaging timeout set on each element it
/// messages. The timeout is per element on purpose: set on the system-wide element
/// it becomes process-wide and would change every other Accessibility read the app
/// makes (`FocusedElementInspector`, the in-place refiner).
///
/// The system calls are closures so the rules — private apps, secure input, the cut —
/// are testable without Accessibility.
struct SelectionReader: Sendable {
    /// The front app, taken on the main actor at the chord press.
    struct FrontApp: Equatable, Sendable {
        var bundleID: String?
        var name: String
        var pid: pid_t

        @MainActor
        static func current() -> FrontApp? {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return FrontApp(bundleID: app.bundleIdentifier,
                            name: app.localizedName ?? "",
                            pid: app.processIdentifier)
        }
    }

    /// Characters of one selection the model sees. Small on purpose: `AgentLoop.render`
    /// sends a tool result again on every later turn, and `MlxCleanupService`'s
    /// generation neither truncates the prompt nor times prompt processing, so a long
    /// selection stalls the on-device model and can exhaust memory.
    static let limit = 8_000

    /// Apps whose selection is never read. A password manager's selection is a
    /// password far more often than it is prose. Lowercased, and matched lowercased,
    /// so a casing difference cannot let one through.
    static let privateApps: Set<String> = [
        "com.1password.1password",          // 1Password 8
        "com.agilebits.onepassword7",       // 1Password 7
        "com.bitwarden.desktop",            // Bitwarden
        "com.dashlane.dashlanephonefinal",  // Dashlane (App Store)
        "com.dashlane.dashlane",            // Dashlane
        "com.lastpass.lastpass",            // LastPass
        "com.lastpass.lastpassmacdesktop",  // LastPass (App Store)
        "org.keepassxc.keepassxc",          // KeePassXC
        "com.apple.keychainaccess",         // Keychain Access
        "com.apple.passwords",              // Passwords (macOS 15+)
        "in.sinew.enpass-desktop",          // Enpass
        "me.proton.pass.electron",          // Proton Pass
        "com.hicknhacksoftware.macpass",    // MacPass
        "com.nordsec.nordpass",             // NordPass
    ]

    /// Per element, in seconds. A hung app costs at most this per message.
    static let messagingTimeout: Float = 0.25
    /// The window title's per-element timeout, and how long the selection may take
    /// before the title is skipped. The title is a nicety read last: 0.1 s here plus
    /// two 0.1 s messages stays inside `SelectionCapture.wait`, so it never costs the
    /// command its selection.
    static let titleTimeout: Float = 0.1

    var secureInputEnabled: @Sendable () -> Bool
    var windowTitle: @Sendable (pid_t) -> String?
    var selectedText: @Sendable (pid_t) -> String?

    /// The selection in `app`, or nil: no app, a private app, secure input on, our
    /// own process, or nothing selected. Blocking; never call it on the main actor.
    func read(_ app: FrontApp?) -> SelectionContext? {
        guard let app, app.pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        if let id = app.bundleID, Self.privateApps.contains(id.lowercased()) { return nil }
        // Secure input is on while a password field anywhere has focus.
        guard !secureInputEnabled() else { return nil }
        let started = Date()
        guard let raw = selectedText(app.pid),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let length = raw.count
        let answeredAtOnce = Date().timeIntervalSince(started) < TimeInterval(Self.titleTimeout)
        return SelectionContext(
            appName: app.name,
            windowTitle: answeredAtOnce ? windowTitle(app.pid) : nil,
            text: length > Self.limit ? String(raw.prefix(Self.limit)) : raw,
            wasCut: length > Self.limit,
            originalLength: length)
    }

    static let live = SelectionReader(
        secureInputEnabled: { TerminalApps.secureKeyboardEntryEnabled() },
        windowTitle: { pid in
            child(of: AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute,
                  timeout: titleTimeout)
                .flatMap { FocusedElementInspector.stringAttribute($0, kAXTitleAttribute) }
        },
        selectedText: { pid in
            // shortcut: Chrome and Electron apps (Slack, VS Code) hide their tree until
            // AXManualAccessibility is set on them, so this reads nil there. Setting it
            // changes another app's behaviour, which is the owner's call.
            child(of: AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute,
                  timeout: messagingTimeout)
                .flatMap { element in
                    // Secure input is global and may be off while a revealed field
                    // still holds a secret, so the element's own subrole is asked too.
                    if FocusedElementInspector.stringAttribute(element, kAXSubroleAttribute)
                        == (kAXSecureTextFieldSubrole as String) { return nil }
                    return FocusedElementInspector.stringAttribute(element, kAXSelectedTextAttribute)
                }
        })

    /// An attribute whose value is itself an element, with the timeout set on the
    /// parent before the call and on the child before anyone messages it.
    private static func child(of parent: AXUIElement, _ attribute: String,
                              timeout: Float) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(parent, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }
}

/// One chord press's selection read: started at the press, consumed by the command.
///
/// `begin` returns at once — the recording has already started, and nothing here may
/// hold it up — and `settle` waits for the read, but never longer than `wait`. A read
/// still blocked in a hung app is walked away from, the same way `AgentLoop` walks
/// away from a stalled generation, because a blocking Accessibility call cannot be
/// cancelled.
@MainActor
final class SelectionCapture {
    nonisolated static let wait: TimeInterval = 0.5

    private let reader: SelectionReader
    private var pending: Task<SelectionContext?, Never>?
    /// The app in front at the press, kept whether or not it had a selection: a draft
    /// may only type into the app the user was speaking to. Read it before `take()`,
    /// which forgets it with the read.
    private(set) var frontApp: SelectionReader.FrontApp?
    /// A press this session accepted saw a password manager in front or secure input
    /// on, so the capture stays off the endpoint. Read at stop with `frontApp`: a press
    /// refused, or made while this capture is still finishing, never reaches it.
    private(set) var staysLocal = false

    init(reader: SelectionReader = .live) {
        self.reader = reader
    }

    /// Start reading `app`'s selection off the main actor. A second press in the same
    /// session keeps the first read: that is when the user had just selected.
    func begin(_ app: SelectionReader.FrontApp?) {
        // Before the guard: either press of one session keeps it local.
        staysLocal = staysLocal || AgentEndpoint.staysLocal(
            frontBundleID: app?.bundleID, secureInput: reader.secureInputEnabled())
        guard pending == nil else { return }
        frontApp = app
        let reader = reader
        pending = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: reader.read(app))
                }
            }
        }
    }

    /// Start the recording, then begin the read. The order is the point: the read must
    /// not delay the first word, and `startRecording` takes any pending read, so a read
    /// begun first would be thrown away by the start.
    func begin(after start: () -> Void,
               app: @MainActor () -> SelectionReader.FrontApp? = SelectionReader.FrontApp.current) {
        start()
        begin(app())
    }

    /// Hand over this session's read and forget it, so it cannot reach the next one.
    func take() -> Task<SelectionContext?, Never>? {
        defer {
            pending = nil
            frontApp = nil
            staysLocal = false
        }
        return pending
    }

    /// The read's result, or nil once `seconds` have passed without one.
    static func settle(_ read: Task<SelectionContext?, Never>?,
                       within seconds: TimeInterval = wait) async -> SelectionContext? {
        guard let read else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<SelectionContext?, Never>) in
            let race = FirstPastThePost()
            let timeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                if race.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let value = await read.value
                timeout.cancel()
                if race.claim() { continuation.resume(returning: value) }
            }
        }
    }
}
