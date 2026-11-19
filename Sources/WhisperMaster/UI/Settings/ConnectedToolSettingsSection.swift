import SwiftUI

/// Settings → Assistant → **Connected tool** (dev builds only,
/// `FeatureFlags.agentEndpointAvailable`): the user's own coding tool as the chord's
/// brain, ahead of the endpoint (`ConnectedTool`).
///
/// Finding the tool is file checks only. **Test** runs it once with a fixed prompt, on a
/// tap only, because each run uses the user's plan. It also proves the tool starts with
/// no tools, MCP servers or hooks of its own, and pins the file it ran. Nothing is sent
/// until the Test has passed on the file this Mac has and the consent sheet is accepted.
/// Only a kind this build offers is ever shown, found or run. The app never offers to
/// install the tool: it is a client only.
///
/// It takes a binding and an optional detection, so the snapshot renderer draws each
/// state without starting anything or writing the defaults of the process it runs in.
struct ConnectedToolSettingsSection: View {
    @Binding var tool: ConnectedTool
    /// Set by the snapshot renderer. nil finds the tool for real.
    var detection: ConnectedTool.Detection?
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var found: ConnectedTool.Detection?
    @State private var testResult: ConnectedTool.TestResult?
    @State private var testing = false
    @State private var showingConsent = false

    /// A stored kind this build does not offer is never used here.
    private var kind: ConnectedTool.Kind { tool.availableKind ?? .claudeCode }
    private var shown: ConnectedTool.Detection? { detection ?? found }

    /// The Test passed on the file this Mac has now.
    private var testedHere: Bool {
        tool.isTested && shown?.binary != nil && tool.tested?.binary == shown?.binary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Connected tool")
            SettingsCard {
                SettingsRow(
                    "Use a connected tool",
                    tag: "Dev",
                    subtitle: "Runs \(kind.name) on this Mac, signed in with your own account, and the "
                        + "chord's text goes to it. The on-device assistant answers when it can't. "
                        + "Audio never leaves this Mac."
                ) {
                    status
                }
                RowDivider()
                SettingsRow("Tool", subtitle: foundSubtitle) {
                    HStack(spacing: 12) {
                        if !isSnapshot {
                            Button("Check again") { find() }
                                .textButton()
                        }
                        toolPicker
                    }
                }
                RowDivider()
                SettingsRow("Test", subtitle: testSubtitle) {
                    Button(testing ? "Testing\u{2026}" : "Test") { runTest() }
                        .secondaryButton()
                        .disabled(shown?.path == nil || testing)
                }
                RowDivider()
                consentRow
            }
        }
        .task(id: kind) { find() }
        .sheet(isPresented: $showingConsent) {
            Self.consentSheet(
                kind: kind,
                program: shown?.binary?.path,
                onAllow: {
                    tool.kind = kind
                    tool.consentedTo = kind
                    tool.paused = false
                    showingConsent = false
                },
                onCancel: { showingConsent = false })
        }
    }

    /// The endpoint's sheet in the tool's words. The API key line is left out: the app
    /// holds no key for the tool. "No tools of its own" is not true for Codex today,
    /// which is one reason its flag is off.
    /// - Parameter program: the file that runs, after every link, so the user agrees to a
    ///   program and not only to a name.
    static func consentSheet(kind: ConnectedTool.Kind, program: String?, onAllow: @escaping () -> Void,
                             onCancel: @escaping () -> Void) -> AgentEndpointConsentSheet {
        AgentEndpointConsentSheet(
            host: kind.name,
            intro: "When you hold fn + control, Whisper Master starts \(kind.name) on this Mac"
                + (program.map { " (\(ConnectedTool.displayPath($0)))" } ?? "") + " and "
                + "gives it the assistant's conversation. \(kind.name) sends it to \(kind.vendor), "
                + "under your own account, and \(kind.vendor)'s terms and retention apply. "
                + "\(kind.name) gets no tools of its own: every action still goes through this app "
                + "and its approval cards.",
            sentItems: AgentEndpointConsentSheet.conversation,
            neverSentItems: AgentEndpointConsentSheet.neverSent
                + ["Your sign-in. The app starts \(kind.name) and never reads its login."],
            footer: "You can pause it from the menu bar. The on-device assistant answers whenever "
                + "\(kind.name) can't.",
            onAllow: onAllow,
            onCancel: onCancel)
    }

    // MARK: - Pieces

    private var statusText: (String, Color) {
        guard let shown else { return ("Looking", Theme.textFaint) }
        if shown.path == nil { return ("Not found", Theme.textFaint) }
        if testResult == .notSignedIn { return ("Not signed in", Theme.warning) }
        if !testedHere { return ("Not tested", Theme.warning) }
        if !tool.hasConsent { return ("Not allowed yet", Theme.warning) }
        if tool.paused { return ("Paused", Theme.textFaint) }
        return ("On", Theme.success)
    }

    private var status: some View {
        HStack(spacing: 8) {
            StatusDot(color: statusText.1, size: 7)
            Text(statusText.0)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var foundSubtitle: String {
        guard let shown else { return "Looking for it on this Mac\u{2026}" }
        guard let path = shown.path else {
            return "Not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin. Install it "
                + "yourself, then check again."
        }
        // The link and the file it runs, so the user sees which program it is.
        let file = shown.binary.flatMap { $0.path == path.path ? nil : $0.path }
        return ConnectedTool.displayPath(path.path) + (file.map { " \u{2192} " + ConnectedTool.displayPath($0) } ?? "")
    }

    private var testSubtitle: String {
        if testing { return "Running it once with a fixed prompt\u{2026}" }
        switch testResult {
        case .notSignedIn?:
            return "Not signed in. Open Terminal, run \(kind.binary), and sign in."
        case .notLean(let what)?:
            return "Not used: it \(what). The chord's text must not reach them."
        case .failed(let why)?:
            return "Didn't pass: it \(why)."
        case .passed?, nil:
            break
        }
        if testedHere, let version = tool.tested?.version {
            return "Passed on \(version): signed in, with no tools, MCP servers or hooks of its own."
        }
        if tool.isTested, let version = tool.tested?.version, shown?.binary != nil {
            return "Passed on \(version), and the file has changed since (an update or a reinstall). "
                + "Test it again before anything is sent."
        }
        return "Runs it once with a fixed prompt, on your plan. It checks the sign-in, and that it "
            + "starts with no tools, MCP servers or hooks of its own."
    }

    @ViewBuilder
    private var toolPicker: some View {
        let kinds = ConnectedTool.Kind.allCases.filter(\.isAvailable)
        if kinds.count > 1, !isSnapshot {
            Picker("", selection: Binding(get: { kind }, set: { tool.kind = $0 })) {
                ForEach(kinds) { Text($0.name).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
        } else {
            Text(kind.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    @ViewBuilder
    private var consentRow: some View {
        if tool.hasConsent {
            SettingsRow(
                "Send to \(kind.name)",
                subtitle: "You allowed the chord's text to go to \(kind.name). Pause it here or from "
                    + "the menu bar; while it is paused, your endpoint answers if it is on."
            ) {
                HStack(spacing: 12) {
                    Button("Revoke") { tool.consentedTo = nil }
                        .textButton()
                    ThemeToggle(isOn: Binding(get: { !tool.paused }, set: { tool.paused = !$0 }),
                                label: "Send to the connected tool")
                        .disabled(isSnapshot)
                }
            }
        } else {
            SettingsRow(
                "Allow this tool",
                subtitle: testedHere
                    ? "Nothing is sent until you review what goes to \(kind.name) and allow it."
                    : "Test it first."
            ) {
                Button("Review and allow\u{2026}") { showingConsent = true }
                    .primaryButton()
                    .disabled(!testedHere)
            }
        }
    }

    // MARK: - Actions

    /// File checks only: nothing starts, nothing leaves this Mac.
    private func find() {
        guard detection == nil, !isSnapshot else { return }
        found = ConnectedTool.detect(kind)
    }

    private func runTest() {
        guard let path = shown?.path else { return }
        let kind = kind
        testing = true
        Task {
            let result = await ConnectedTool.test(kind, at: path)
            testing = false
            testResult = result
            if case .passed(let tested) = result {
                tool.kind = kind
                tool.tested = tested
                find()
            } else if tool.tested?.kind == kind {
                // A tool that fails its Test sends nothing until it passes again.
                tool.tested = nil
            }
        }
    }
}
