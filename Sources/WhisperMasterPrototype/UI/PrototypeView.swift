import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case recording
    case engine
    case history
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: return "Recording"
        case .engine: return "Voice engine"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .recording: return "mic.fill"
        case .engine: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recording: return .orange
        case .engine: return .purple
        case .history: return .blue
        case .permissions: return .green
        case .about: return .gray
        }
    }
}

struct PrototypeView: View {
    let viewModel: PrototypeViewModel
    @Bindable var state: PrototypeAppState
    var reopenOnboarding: () -> Void = {}
    var startSetup: () -> Void = {}
    var cancelSetup: () -> Void = {}

    @State private var selection: SettingsSection = .recording
    @State private var hasAutoFocusedSetup = false
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    private let permissions = PermissionsManager()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 460, ideal: 540)
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear {
            refreshPermissions()
            autoFocusSetupIfNeeded()
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(SettingsSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.icon)
                                .foregroundStyle(section.tint)
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.orange)
                    Text("Whisper Master")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.bottom, 2)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("v0.1.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHeader
                if shouldShowSetupBanner {
                    setupBanner
                }
                panelContent
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.title)
                .font(.system(size: 22, weight: .bold))
            Text(headerSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var headerSubtitle: String {
        switch selection {
        case .recording: return "How recording starts, stops, and pastes."
        case .engine: return "Pick the on-device transcription engine."
        case .history: return "Recent transcripts, ready to paste again."
        case .permissions: return "Whisper Master needs these to listen and type."
        case .about: return "Version info and helpful resets."
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selection {
        case .recording: recordingForm
        case .engine: engineForm
        case .history: historyPanel
        case .permissions: permissionsForm
        case .about: aboutForm
        }
    }

    // MARK: - Recording

    private var recordingForm: some View {
        Form {
            Section {
                LabeledContent("Push-to-talk key") {
                    Picker("", selection: hotkeyBinding) {
                        ForEach(HotkeyManager.HotkeyOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 190)
                }

                Toggle(isOn: $state.holdToTalkEnabled) {
                    Text("Hold-to-talk")
                    Text("Hold the key while you speak. Off makes it a toggle.")
                }

                Toggle(isOn: $state.autoPasteEnabled) {
                    Text("Auto-paste at cursor")
                    Text("Insert the transcription wherever you're typing.")
                }

                Toggle(isOn: $state.soundEnabled) {
                    Text("Play start / stop sound")
                    Text("Subtle click when recording begins or ends.")
                }

                Toggle(isOn: $state.preferBuiltInMic) {
                    Text("Always use built-in mic")
                    Text("Ignore external audio devices.")
                }
            }

            Section("Appearance") {
                Toggle(isOn: $state.hidePillWhenIdle) {
                    Text("Hide pill when idle")
                    Text("Floating dictation pill is hidden between recordings.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(minHeight: 420)
    }

    // MARK: - Engine

    private var engineForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 10) {
                ForEach(TranscriberEngine.allCases) { engine in
                    engineCard(engine)
                }
            }

            Form {
                Section("Engine status") {
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            if state.preparingEngine == state.selectedEngine {
                                ProgressView().controlSize(.small)
                            } else {
                                Circle()
                                    .fill(modelStatusColor)
                                    .frame(width: 8, height: 8)
                            }
                            Text(modelStatusText)
                                .foregroundStyle(.primary)
                        }
                    }

                    LabeledContent("Stored at") {
                        HStack(spacing: 8) {
                            Text(state.selectedEngine.localModelsRoot.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([state.selectedEngine.localModelURL])
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(minHeight: 160)
        }
    }

    private func engineCard(_ engine: TranscriberEngine) -> some View {
        let isSelected = state.selectedEngine == engine
        let isInstalled = engine.isInstalled
        return Button {
            viewModel.selectEngine(engine)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(engine.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        if isInstalled {
                            Text("Installed")
                                .font(.caption2.bold())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.18))
                                .foregroundStyle(Color.green)
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text(engine.estimatedDownloadSize)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(engine.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!engineSelectionEnabled)
        .opacity(engineSelectionEnabled ? 1 : 0.55)
    }

    // MARK: - History

    private var historyPanel: some View {
        Group {
            if state.history.isEmpty {
                emptyHistory
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    historyToolbar
                    historyList
                }
            }
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No transcripts yet")
                .font(.headline)
            Text("Hold your push-to-talk key and dictate. Finished transcripts will land here, ready to paste again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var historyToolbar: some View {
        HStack {
            Text("\(state.history.count) saved")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                viewModel.pasteLastTranscript()
            } label: {
                Label("Paste last", systemImage: "arrow.up.doc.on.clipboard")
            }
            .disabled(state.history.isEmpty)

            Button(role: .destructive) {
                viewModel.clearAllHistory()
            } label: {
                Label("Clear all", systemImage: "trash")
            }
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.history.enumerated()), id: \.element.id) { idx, entry in
                historyRow(entry)
                if idx < state.history.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    private func historyRow(_ entry: TranscriptHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(Self.historyDateFormatter.string(from: entry.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let engine = TranscriberEngine(rawValue: entry.engineRawValue) {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(engine.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Button { viewModel.copyToClipboard(entry.text) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy")

                Button { viewModel.pasteText(entry.text) } label: {
                    Image(systemName: "arrow.up.doc.on.clipboard")
                }
                .help("Paste at cursor")

                Button(role: .destructive) { viewModel.deleteHistoryEntry(entry.id) } label: {
                    Image(systemName: "trash")
                }
                .help("Delete")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private static let historyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Permissions

    private var permissionsForm: some View {
        Form {
            Section {
                permissionRow(
                    icon: "mic.fill",
                    tint: .orange,
                    title: "Microphone",
                    detail: "Required to listen while you hold the record key.",
                    granted: micGranted,
                    denied: micDenied
                ) {
                    permissions.openMicrophoneSettings()
                }

                permissionRow(
                    icon: "keyboard",
                    tint: .blue,
                    title: "Accessibility",
                    detail: "Required for auto-paste at the cursor.",
                    granted: accessibilityGranted,
                    denied: false
                ) {
                    permissions.promptAccessibility()
                    permissions.openAccessibilitySettings()
                }
            } footer: {
                Text("Status refreshes automatically when you return from System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(minHeight: 280)
    }

    private func permissionRow(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        granted: Bool,
        denied: Bool,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(denied ? "Open Settings" : "Grant", action: action)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - About

    private var aboutForm: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 56, height: 56)
                        Image(systemName: "waveform")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whisper Master")
                            .font(.headline)
                        Text("Version 0.1.0")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Local-first dictation, FluidAudio + Parakeet on Apple Silicon.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section("Actions") {
                LabeledContent("Reopen onboarding") {
                    Button("Reopen") { reopenOnboarding() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(minHeight: 280)
    }

    // MARK: - Setup banner

    private var shouldShowSetupBanner: Bool {
        if state.preparingEngine != nil { return true }
        if case .failed = state.phase { return !state.selectedEngine.isInstalled }
        return !state.selectedEngine.isInstalled
    }

    private var setupBanner: some View {
        let preparing = state.preparingEngine == state.selectedEngine
        let isFailed: Bool = {
            if case .failed = state.phase { return true }
            return false
        }()
        let percent = Int((state.download?.fractionCompleted ?? 0) * 100)
        let progress = state.download?.fractionCompleted ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isFailed ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    if preparing {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isFailed ? .red : Color.accentColor)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(setupHeadline)
                        .font(.headline)
                    Text(setupSubhead)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if preparing {
                    Text("\(percent)%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                }
            }
            if preparing {
                ProgressView(value: progress)
            }
            HStack {
                if preparing {
                    Button("Cancel", action: cancelSetup)
                } else {
                    Button(action: startSetup) {
                        Label("Download voice engine", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open details") { selection = .engine }
                }
                Spacer()
                Text(state.selectedEngine.estimatedDownloadSize)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFailed ? Color.red.opacity(0.45) : Color.accentColor.opacity(0.4), lineWidth: 1)
        )
    }

    private var setupHeadline: String {
        if case .failed = state.phase, !state.selectedEngine.isInstalled {
            return "Couldn't finish setup"
        }
        if state.preparingEngine == state.selectedEngine {
            return state.selectedEngine.isInstalled
                ? "Loading \(state.selectedEngine.displayName) engine…"
                : "Downloading \(state.selectedEngine.displayName) engine…"
        }
        return "Voice engine not installed"
    }

    private var setupSubhead: String {
        if case .failed(let msg) = state.phase, !state.selectedEngine.isInstalled {
            return msg
        }
        if state.preparingEngine == state.selectedEngine {
            return state.download?.detail ?? "Preparing on-device model. This only happens once."
        }
        return "One-time download of the on-device model. Whisper Master can't transcribe until this finishes."
    }

    // MARK: - Helpers

    private func autoFocusSetupIfNeeded() {
        guard !hasAutoFocusedSetup else { return }
        hasAutoFocusedSetup = true
        if !state.selectedEngine.isInstalled || state.preparingEngine != nil {
            selection = .engine
        }
    }

    private func refreshPermissions() {
        let micStatus = permissions.microphoneStatus()
        micGranted = micStatus == .granted
        micDenied = micStatus == .denied
        accessibilityGranted = permissions.accessibilityGranted()
    }

    private var hotkeyBinding: Binding<HotkeyManager.HotkeyOption> {
        Binding(
            get: { state.hotkey },
            set: { viewModel.updateHotkey($0) }
        )
    }

    private var engineSelectionEnabled: Bool {
        switch state.phase {
        case .idle, .failed: return true
        case .preparingModels, .recording, .stopping: return false
        }
    }

    private var modelStatusText: String {
        if let download = state.download, state.preparingEngine == state.selectedEngine {
            return "\(download.detail) \(Int(download.fractionCompleted * 100))%"
        }
        if state.preparingEngine == state.selectedEngine {
            return state.selectedEngine.isInstalled ? "Loading…" : "Downloading…"
        }
        if state.preparedEngine == state.selectedEngine {
            return "Ready"
        }
        return state.selectedEngine.isInstalled ? "Ready on this Mac" : "Setup needed"
    }

    private var modelStatusColor: Color {
        if state.preparingEngine == state.selectedEngine { return Color.accentColor }
        return state.selectedEngine.isInstalled ? .green : .secondary
    }

    private var statusColor: Color {
        switch state.phase {
        case .recording: return .red
        case .preparingModels: return .orange
        case .failed: return .red
        case .idle, .stopping:
            return (micGranted && accessibilityGranted) ? .green : .secondary
        }
    }

    private var statusLabel: String {
        switch state.phase {
        case .recording: return "Recording"
        case .preparingModels: return "Preparing…"
        case .stopping: return "Finalizing…"
        case .failed: return "Error"
        case .idle:
            if !micGranted || !accessibilityGranted { return "Needs attention" }
            return "Ready"
        }
    }
}
