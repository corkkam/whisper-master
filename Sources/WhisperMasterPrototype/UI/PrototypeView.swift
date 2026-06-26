import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case recording
    case engine
    case history
    case permissions
    case about

    var id: String { rawValue }

    var index: Int { (SettingsSection.allCases.firstIndex(of: self) ?? 0) + 1 }

    var trackLabel: String {
        String(format: "TRACK %02d / %02d", index, SettingsSection.allCases.count)
    }

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
        case .recording: return "mic"
        case .engine: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "shield"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .recording: return "How dictation starts, stops, and lands where you're typing."
        case .engine: return "Everything runs on-device — your audio never leaves this Mac."
        case .history: return "Your recent transcriptions, kept locally and searchable."
        case .permissions: return "Whisper Master only asks for what it needs to work."
        case .about: return "Voice dictation that stays on your Mac."
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
        HStack(spacing: 0) {
            sidebar
            detail
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(Studio.bg)
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
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 22)
                .padding(.top, 48)

            WaveformStrip(barCount: 44, height: 26, accent: Studio.waveBarSoft, base: Studio.waveBarSoft.opacity(0.4))
                .frame(height: 26)
                .padding(.horizontal, 22)
                .padding(.top, 22)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    navRow(section)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 26)

            Spacer(minLength: 0)

            sidebarFooter
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        .background(Studio.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 12) {
            BrandLogo(size: 44, cornerRadius: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper Master")
                    .font(StudioFont.sans(17, .bold))
                    .foregroundStyle(Studio.cream)
                Text("STUDIO")
                    .font(StudioFont.monoSmall)
                    .tracking(3)
                    .foregroundStyle(Studio.red)
            }
        }
    }

    private func navRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 14) {
                Text(String(format: "%02d", section.index))
                    .font(StudioFont.monoSmall)
                    .foregroundStyle(isSelected ? Studio.cream.opacity(0.7) : Studio.creamTertiary)
                Text(section.title)
                    .font(StudioFont.sans(15, .semibold))
                    .foregroundStyle(isSelected ? .white : Studio.creamSecondary)
                Spacer()
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : Studio.creamTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Studio.red : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel.uppercased())
                    .font(StudioFont.mono)
                    .tracking(1.5)
                    .foregroundStyle(Studio.cream)
            }
            Text("V\(AppInfo.version) · \(state.hotkey.compactName) TO DICTATE")
                .font(StudioFont.monoSmall)
                .tracking(1)
                .foregroundStyle(Studio.creamTertiary)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                detailHeader
                WaveformStrip(barCount: 96, height: 78, accent: Studio.red, base: Studio.waveBar)
                    .frame(height: 78)
                if shouldShowSetupBanner, selection != .engine {
                    setupBanner
                }
                panelContent
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Studio.bg)
    }

    private var detailHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(selection.trackLabel)
                    .font(StudioFont.mono)
                    .tracking(2)
                    .foregroundStyle(Studio.red)
                Text(selection.title)
                    .font(StudioFont.display)
                    .foregroundStyle(Studio.ink)
                Text(selection.subtitle)
                    .font(StudioFont.subtitle)
                    .foregroundStyle(Studio.inkSecondary)
            }
            Spacer(minLength: 16)
            InputLevelMeter(level: state.audioLevel)
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selection {
        case .recording: recordingPanel
        case .engine: enginePanel
        case .history: historyPanel
        case .permissions: permissionsPanel
        case .about: aboutPanel
        }
    }

    // MARK: - Recording

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioCard {
                SettingRow(code: "A1", title: "Push-to-talk key",
                           detail: "Press and hold to dictate from anywhere on your Mac.") {
                    hotkeyMenu
                }
                rowDivider
                SettingRow(code: "A2", title: "Hold-to-talk",
                           detail: "Hold the key while you speak. Off makes it a toggle.") {
                    Toggle("", isOn: $state.holdToTalkEnabled).toggleStyle(StudioToggleStyle())
                }
                rowDivider
                SettingRow(code: "A3", title: "Auto-paste at cursor",
                           detail: "Insert the transcription wherever you're typing.") {
                    Toggle("", isOn: $state.autoPasteEnabled).toggleStyle(StudioToggleStyle())
                }
                rowDivider
                SettingRow(code: "A4", title: "Play start / stop sound",
                           detail: "Subtle click when recording begins or ends.") {
                    Toggle("", isOn: $state.soundEnabled).toggleStyle(StudioToggleStyle())
                }
            }

            sectionLabel("APPEARANCE")

            StudioCard {
                SettingRow(code: "B1", title: "Hide pill when idle",
                           detail: "The floating dictation pill stays hidden between recordings.") {
                    Toggle("", isOn: $state.hidePillWhenIdle).toggleStyle(StudioToggleStyle())
                }
            }
        }
    }

    private var hotkeyMenu: some View {
        Menu {
            ForEach(HotkeyManager.HotkeyOption.allCases) { option in
                Button {
                    viewModel.updateHotkey(option)
                } label: {
                    if option == state.hotkey {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(state.hotkey.compactName)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Studio.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Studio.inkSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Studio.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Studio.ink.opacity(0.55), lineWidth: 1.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Engine

    /// Two-way bridge between the newline-separated editor text and the
    /// `[String]` glossary in state.
    private var vocabularyText: Binding<String> {
        Binding(
            get: { state.customVocabulary.joined(separator: "\n") },
            set: { newValue in
                state.customVocabulary = newValue
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var enginePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(TranscriberEngine.allCases) { engine in
                engineCard(engine)
            }

            sectionLabel("ENGINE STATUS")
                .padding(.top, 6)

            StudioCard {
                SettingRow(code: "S1", title: "Status", detail: nil) {
                    engineStatusBadge
                }
                rowDivider
                SettingRow(code: "S2", title: "Model location", detail: nil) {
                    HStack(spacing: 12) {
                        Text("~/Library/…/FluidAudio/Models")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Studio.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        StudioButton(title: "Reveal", icon: "folder", filled: false) {
                            NSWorkspace.shared.activateFileViewerSelecting([state.selectedEngine.localModelURL])
                        }
                    }
                }
            }

            sectionLabel("WORDS TO GET RIGHT")
                .padding(.top, 6)

            StudioCard(padding: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Names, acronyms, or jargon the app keeps mishearing — one per line. It listens harder for these, so e.g. \u{201C}RAG\u{201D} stops coming out as \u{201C}rack\u{201D}.")
                        .font(StudioFont.cardBody)
                        .foregroundStyle(Studio.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ZStack(alignment: .topLeading) {
                        if state.customVocabulary.isEmpty {
                            Text("RAG\nParakeet\nLyzr")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Studio.inkTertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: vocabularyText)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Studio.ink)
                            .scrollContentBackground(.hidden)
                            .frame(height: 88)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Studio.bg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Studio.cardBorder, lineWidth: 1)
                    )

                    Text("One word or phrase per line. Saved automatically.")
                        .font(StudioFont.monoSmall)
                        .foregroundStyle(Studio.inkTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var engineStatusBadge: some View {
        if state.preparingEngine == state.selectedEngine {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(modelStatusText.uppercased())
                    .font(StudioFont.mono)
                    .foregroundStyle(Studio.inkSecondary)
            }
        } else {
            let ready = state.selectedEngine.isInstalled
            HStack(spacing: 8) {
                Circle()
                    .fill(ready ? Studio.green : Studio.inkTertiary)
                    .frame(width: 9, height: 9)
                Text((ready ? "READY" : "SETUP NEEDED"))
                    .font(StudioFont.mono)
                    .tracking(1)
                    .foregroundStyle(ready ? Studio.green : Studio.inkSecondary)
            }
        }
    }

    private func engineCard(_ engine: TranscriberEngine) -> some View {
        let isSelected = state.selectedEngine == engine
        return Button {
            viewModel.selectEngine(engine)
        } label: {
            HStack(spacing: 18) {
                RadialKnob(selected: isSelected)
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.displayName)
                        .font(StudioFont.cardTitle)
                        .foregroundStyle(isSelected ? Studio.cream : Studio.ink)
                    Text(engine.subtitle)
                        .font(StudioFont.cardBody)
                        .foregroundStyle(isSelected ? Studio.creamSecondary : Studio.inkSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(engine.estimatedDownloadSize)
                        .font(StudioFont.sans(22, .bold))
                        .foregroundStyle(isSelected ? Studio.cream : Studio.ink)
                    Text(engine.isInstalled ? "INSTALLED" : "NOT INSTALLED")
                        .font(StudioFont.monoSmall)
                        .tracking(1)
                        .foregroundStyle(isSelected ? Studio.creamSecondary : Studio.inkTertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Studio.dark : Studio.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Studio.cardBorder, lineWidth: 1)
            )
            .shadow(color: Studio.cardShadow, radius: 10, y: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!engineSelectionEnabled)
        .opacity(engineSelectionEnabled ? 1 : 0.55)
    }

    // MARK: - History

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                statCard(value: "\(wordsDictatedToday)", label: "Words dictated today", accent: true)
                statCard(value: "\(state.history.count)", label: "Transcripts saved", accent: false)
            }

            if state.history.isEmpty {
                emptyHistory
            } else {
                HStack {
                    sectionLabel("RECENT")
                    Spacer()
                    Button("Clear all") { viewModel.clearAllHistory() }
                        .buttonStyle(.plain)
                        .font(StudioFont.monoSmall)
                        .tracking(1)
                        .foregroundStyle(Studio.red)
                }
                StudioCard(padding: 0) {
                    let entries = Array(state.history.prefix(12))
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        historyRow(entry)
                        if idx < entries.count - 1 { rowDivider }
                    }
                }
            }
        }
    }

    private func statCard(value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(StudioFont.stat)
                .foregroundStyle(accent ? Studio.red : Studio.ink)
            Text(label)
                .font(StudioFont.sans(14, .medium))
                .foregroundStyle(Studio.inkSecondary)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Studio.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Studio.cardBorder, lineWidth: 1)
        )
        .shadow(color: Studio.cardShadow, radius: 10, y: 5)
    }

    private func historyRow(_ entry: TranscriptHistoryEntry) -> some View {
        let engine = TranscriberEngine(rawValue: entry.engineRawValue)
        let words = entry.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        return HStack(alignment: .top, spacing: 18) {
            Text(Self.historyTimeFormatter.string(from: entry.createdAt).uppercased())
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Studio.inkTertiary)
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.text)
                    .font(StudioFont.sans(15, .regular))
                    .foregroundStyle(Studio.ink)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Text("\(words) WORDS")
                        .foregroundStyle(Studio.inkTertiary)
                    if let engine {
                        Text(engine.displayName.uppercased())
                            .foregroundStyle(Studio.red)
                    }
                }
                .font(StudioFont.monoSmall)
                .tracking(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                iconButton("doc.on.doc", help: "Copy") { viewModel.copyToClipboard(entry.text) }
                iconButton("arrow.up.doc.on.clipboard", help: "Paste at cursor") { viewModel.pasteText(entry.text) }
                iconButton("trash", help: "Delete") { viewModel.deleteHistoryEntry(entry.id) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Studio.inkSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Studio.bg)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var emptyHistory: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(Studio.inkTertiary)
            Text("No transcripts yet")
                .font(StudioFont.sans(17, .bold))
                .foregroundStyle(Studio.ink)
            Text("Hold your push-to-talk key and dictate. Finished transcripts land here, ready to paste again.")
                .font(StudioFont.cardBody)
                .foregroundStyle(Studio.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(44)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Studio.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Studio.cardBorder, lineWidth: 1)
        )
    }

    private var wordsDictatedToday: Int {
        let calendar = Calendar.current
        return state.history
            .filter { calendar.isDateInToday($0.createdAt) }
            .reduce(0) { $0 + $1.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }
    }

    private static let historyTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    // MARK: - Permissions

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            StudioCard {
                permissionRow(
                    code: "P1",
                    title: "Microphone",
                    detail: "Required to capture your voice.",
                    granted: micGranted,
                    denied: micDenied
                ) {
                    permissions.openMicrophoneSettings()
                }
                rowDivider
                permissionRow(
                    code: "P2",
                    title: "Accessibility",
                    detail: "Lets Whisper paste text at your cursor.",
                    granted: accessibilityGranted,
                    denied: false
                ) {
                    permissions.promptAccessibility()
                    permissions.openAccessibilitySettings()
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "shield")
                    .font(.system(size: 11, weight: .bold))
                Text("ALL PROCESSING HAPPENS ON-DEVICE. NOTHING IS UPLOADED.")
                    .font(StudioFont.monoSmall)
                    .tracking(1.5)
            }
            .foregroundStyle(Studio.inkTertiary)
            .padding(.leading, 4)
        }
    }

    private func permissionRow(
        code: String,
        title: String,
        detail: String,
        granted: Bool,
        denied: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SettingRow(code: code, title: title, detail: detail) {
            if granted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                    Text("GRANTED")
                        .font(StudioFont.mono)
                        .tracking(1)
                }
                .foregroundStyle(Studio.green)
            } else {
                StudioButton(title: denied ? "Open Settings" : "Grant access", icon: nil, filled: true, action: action)
            }
        }
    }

    // MARK: - About

    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 18) {
                WaveformStrip(barCount: 22, height: 44, accent: Studio.red, base: Studio.red.opacity(0.45), centered: true)
                    .frame(width: 240, height: 44)
                    .padding(.top, 8)
                VStack(spacing: 8) {
                    Text("Whisper Master")
                        .font(StudioFont.sans(28, .heavy))
                        .foregroundStyle(.white)
                    Text("VERSION \(AppInfo.version) · ON-DEVICE DICTATION")
                        .font(StudioFont.mono)
                        .tracking(2)
                        .foregroundStyle(Studio.creamSecondary)
                }
                HStack(spacing: 14) {
                    StudioButton(title: "Reveal models", icon: "folder", filled: false, onDark: true) {
                        NSWorkspace.shared.activateFileViewerSelecting([state.selectedEngine.localModelURL])
                    }
                    StudioButton(title: "Reopen onboarding", icon: "sparkles", filled: true, onDark: true) {
                        reopenOnboarding()
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Studio.dark)
            )
            .shadow(color: Studio.cardShadow, radius: 14, y: 7)

            StudioCard {
                SettingRow(code: "U1", title: "Engine", detail: "On-device transcription.") {
                    Text("Whisper Master \(state.selectedEngine.displayName)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Studio.inkSecondary)
                }
                rowDivider
                SettingRow(code: "U2", title: "Platform", detail: "Built for Apple Silicon.") {
                    Text("macOS 14+ · arm64")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Studio.inkSecondary)
                }
            }
        }
    }

    // MARK: - Setup banner

    private var shouldShowSetupBanner: Bool {
        if state.preparingEngine != nil { return true }
        if case .failed = state.phase { return !state.selectedEngine.isInstalled }
        return !state.selectedEngine.isInstalled
    }

    private var setupBanner: some View {
        let preparing = state.preparingEngine == state.selectedEngine
        let isFailed: Bool = { if case .failed = state.phase { return true }; return false }()
        let percent = Int((state.download?.fractionCompleted ?? 0) * 100)
        let progress = state.download?.fractionCompleted ?? 0

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isFailed ? Studio.red.opacity(0.16) : Studio.red.opacity(0.12))
                        .frame(width: 44, height: 44)
                    if preparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Studio.red)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(setupHeadline)
                        .font(StudioFont.sans(15, .bold))
                        .foregroundStyle(Studio.ink)
                    Text(setupSubhead)
                        .font(StudioFont.cardBody)
                        .foregroundStyle(Studio.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if preparing {
                    Text("\(percent)%")
                        .font(StudioFont.sans(22, .heavy))
                        .foregroundStyle(Studio.red)
                        .monospacedDigit()
                }
            }
            if preparing {
                ProgressView(value: progress).tint(Studio.red)
            }
            HStack {
                if preparing {
                    StudioButton(title: "Cancel", icon: nil, filled: false, action: cancelSetup)
                } else {
                    StudioButton(title: "Download voice engine", icon: "arrow.down.circle", filled: true, action: startSetup)
                    StudioButton(title: "Open engine", icon: nil, filled: false) { selection = .engine }
                }
                Spacer()
                Text(state.selectedEngine.estimatedDownloadSize)
                    .font(StudioFont.monoSmall)
                    .foregroundStyle(Studio.inkTertiary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Studio.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Studio.red.opacity(0.45), lineWidth: 1.5)
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

    // MARK: - Shared bits

    private var rowDivider: some View {
        Rectangle().fill(Studio.divider).frame(height: 1)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 12) {
            Text(text)
                .font(StudioFont.mono)
                .tracking(2)
                .foregroundStyle(Studio.inkTertiary)
            Rectangle().fill(Studio.divider).frame(height: 1)
        }
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
        if state.preparedEngine == state.selectedEngine { return "Ready" }
        return state.selectedEngine.isInstalled ? "Ready on this Mac" : "Setup needed"
    }

    private var statusColor: Color {
        switch state.phase {
        case .recording: return Studio.red
        case .preparingModels: return Studio.red
        case .failed: return Studio.red
        case .idle, .stopping:
            return (micGranted && accessibilityGranted) ? Studio.greenDark : Studio.creamTertiary
        }
    }

    private var statusLabel: String {
        switch state.phase {
        case .recording: return "Recording"
        case .preparingModels: return "Preparing"
        case .stopping: return "Finalizing"
        case .failed: return "Error"
        case .idle:
            if !micGranted || !accessibilityGranted { return "Needs setup" }
            return "Ready"
        }
    }
}

// MARK: - Reusable studio components

private struct StudioCard<Content: View>: View {
    var padding: CGFloat = -1
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(padding >= 0 ? padding : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Studio.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Studio.cardBorder, lineWidth: 1)
            )
            .shadow(color: Studio.cardShadow, radius: 10, y: 5)
    }
}

private struct SettingRow<Control: View>: View {
    let code: String
    let title: String
    let detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 18) {
            Text(code)
                .font(StudioFont.monoSmall)
                .foregroundStyle(Studio.inkTertiary)
                .frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(StudioFont.cardTitle)
                    .foregroundStyle(Studio.ink)
                if let detail {
                    Text(detail)
                        .font(StudioFont.cardBody)
                        .foregroundStyle(Studio.inkSecondary)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}

/// Sunburst dial used for the engine selector.
private struct RadialKnob: View {
    let selected: Bool

    var body: some View {
        ZStack {
            ForEach(0..<24, id: \.self) { i in
                Capsule()
                    .fill(selected ? Studio.cream.opacity(0.85) : Studio.inkTertiary.opacity(0.7))
                    .frame(width: 2, height: 6)
                    .offset(y: -16)
                    .rotationEffect(.degrees(Double(i) / 24 * 360))
            }
            if selected {
                Circle().strokeBorder(Studio.red, lineWidth: 3).frame(width: 26, height: 26)
                Circle().fill(.white).frame(width: 14, height: 14)
            } else {
                Circle().fill(Studio.red).frame(width: 14, height: 14)
            }
        }
        .frame(width: 44, height: 44)
    }
}

/// A deterministic "audio clip" waveform: dark bars with periodic accent bars
/// and the occasional gap rendered as a dot. Purely decorative.
private struct WaveformStrip: View {
    let barCount: Int
    let height: CGFloat
    let accent: Color
    let base: Color
    var centered: Bool = false

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = max(2, geo.size.width / CGFloat(barCount) * 0.35)
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = barHeight(i)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(i % 9 == 4 ? accent : base)
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centered ? .center : .leading)
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let x = Double(i)
        // Layered sines give repeated "clip" envelopes; some bars collapse to dots.
        let env = abs(sin(x * 0.13)) * 0.6 + abs(sin(x * 0.41 + 1.2)) * 0.4
        let gap = sin(x * 0.27) < -0.55
        if gap { return 3 }
        return max(4, CGFloat(0.18 + env) * height)
    }
}

/// Live input-level meter shown top-right, wired to the recording audio level.
private struct InputLevelMeter: View {
    let level: Float
    private let barCount = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INPUT LEVEL")
                    .font(StudioFont.monoSmall)
                    .tracking(1.5)
                    .foregroundStyle(Studio.creamSecondary)
                Spacer()
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Studio.creamSecondary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color(for: i))
                        .frame(width: 4, height: barHeight(i))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Studio.dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var activeBars: Int {
        let lit = Double(min(1, max(0, level * 8))) * Double(barCount)
        return max(1, Int(lit))
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let env = 0.45 + abs(sin(Double(i) * 0.6)) * 0.55
        return CGFloat(env) * 30
    }

    private func color(for i: Int) -> Color {
        if i >= activeBars { return Studio.cream.opacity(0.12) }
        return i >= barCount - 3 ? Studio.red : Studio.cream.opacity(0.85)
    }
}
