import SwiftUI

/// The assistant and spoken-answer preferences, on the **Settings** page.
///
/// These lived on the Connectors page, one scroll under the connection list, because
/// they're downstream of having connections. That put two ordinary preferences —
/// a switch and a voice picker — on a page whose job is managing accounts, and left
/// the Settings page (which is where a preference is looked for) without them. They
/// sit here now, right after Smart cleanup, which is the same on-device model these
/// answers run on.
///
/// What stayed behind is the part that is genuinely *about the connections*: the
/// standing-permission list (`ConnectorPermissionsSection`), which names grants on
/// named accounts and is meaningless away from them.
struct AssistantSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Assistant")
            assistantSection
            speechSection
        }
    }

    // MARK: - Assistant

    /// One card, one question: may the local model read your connectors?
    ///
    /// This used to be the first row of a six-row card that ran on into the whole
    /// speech stack — so the single most consequential switch here (a model touching
    /// your calendar) sat visually level with "which voice". They stay two *cards*,
    /// because they are two decisions, but share the one "Assistant" label: two
    /// headers for three visible rows made the page longer, not clearer.
    private var assistantSection: some View {
            SettingsCard {
                SettingsRow(
                    "Let it use your connectors",
                    subtitle: "The assistant can read anything you have connected. Runs on-device; writes still ask you first."
                ) {
                    ThemeToggle(isOn: $state.connectorAgentEnabled, label: "Connector assistant")
                        .disabled(isSnapshot)
                }
                if state.connectorAgentEnabled {
                    RowDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        // Honest about the model. A 3B sometimes can't produce a usable
                        // answer, and the user should know the fallback exists rather
                        // than wondering why answers vary in richness.
                        Text("It's a small local model, so it won't always manage. When it can't, you get the plain calendar summary instead — never a guess.")
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !state.cleanupModelReady {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.warning)
                                Text("The model isn't downloaded yet — turn on Smart cleanup to fetch it.")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                    .fill(Theme.warningSoft))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
            }
    }

    // MARK: - Reading answers aloud

    /// Speech sits **outside** the `connectorAgentEnabled` branch above: the
    /// deterministic `DaySummaryService` answer is spoken too, so this works whether or
    /// not the user let the model near their connectors.
    private var speechSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Spoken answers")
            SettingsCard {
                // There is no second "also read scheduled answers" switch any more.
                // It existed because an automation could talk unprompted, which is a
                // consent nobody gives by agreeing that questions they ask can be
                // answered — with automations gone, every answer is one the user just
                // asked for out loud, so one switch is the whole decision.
                SettingsRow(
                    "Read answers aloud",
                    subtitle: "Speaks the answer when you ask a question out loud. Uses a voice macOS already has — nothing extra is downloaded."
                ) {
                    ThemeToggle(isOn: $state.speakAnswersEnabled, label: "Read answers aloud")
                        .disabled(isSnapshot)
                }

                if state.speakAnswersEnabled {
                    RowDivider()
                    SettingsRow("Voice", subtitle: voiceSubtitle) {
                        HStack(spacing: 8) {
                            enginePicker
                            if !isSnapshot {
                                IconButton("play.circle", label: "Preview voice") {
                                    viewModel.previewVoice()
                                }
                            }
                        }
                    }
                    switch state.answerVoiceEngine {
                    case .system:
                        RowDivider()
                        systemVoiceRow
                    case .natural:
                        RowDivider()
                        naturalVoiceRow
                    }
                }
            }
        }
    }

    private var voiceSubtitle: String {
        switch state.answerVoiceEngine {
        case .system:
            return "A voice macOS already has. Instant, and it adds nothing to memory."
        case .natural:
            return "A small on-device voice that sounds far more human. About 310 MB, and it's unloaded again a couple of minutes after it stops talking."
        }
    }

    @ViewBuilder
    private var enginePicker: some View {
        if isSnapshot {
            staticValue(state.answerVoiceEngine.label)
        } else {
            Picker("", selection: $state.answerVoiceEngine) {
                ForEach(AnswerVoiceEngine.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
        }
    }

    // MARK: System voice

    @ViewBuilder
    private var systemVoiceRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Which voice")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                systemVoicePicker
            }
            // The stock compact voices sound robotic enough that someone who never
            // learns the good ones are free will fairly conclude this isn't worth using.
            if SystemVoiceCatalog.resolvedVoiceIsBasic(state.systemVoiceIdentifier) {
                betterVoicesHint
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .onAppear {
            // Re-read once on open, and then keep watching: a voice downloaded in
            // System Settings while this page is up should appear here without a
            // relaunch, which is what makes the nudge below feel like it worked.
            SystemVoiceCatalog.invalidate()
            SystemVoiceCatalog.startObservingVoiceChanges()
        }
    }

    @ViewBuilder
    private var systemVoicePicker: some View {
        if isSnapshot {
            staticValue("Automatic")
        } else {
            Picker("", selection: $state.systemVoiceIdentifier) {
                ForEach(SystemVoiceCatalog.installed(selecting: state.systemVoiceIdentifier)) {
                    Text($0.label).tag($0.id)
                }
            }
            .labelsHidden().pickerStyle(.menu).tint(Theme.accent).fixedSize()
        }
    }

    /// There is no API to download a voice or open the voice sheet, so the honest move
    /// is to name the exact path and open the pane. Same shape as the Globe-key conflict
    /// hint in Recording settings.
    private var betterVoicesHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 8) {
                Text("You're on the basic built-in voice, which sounds robotic. macOS has much better ones for free — Accessibility → Spoken Content → System Voice → Manage Voices, then download an Enhanced or Premium voice. It shows up here straight away.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isSnapshot {
                    Button("Open Spoken Content settings") {
                        SystemVoiceCatalog.openSpokenContentSettings()
                    }
                    .textButton()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.warningSoft)
        )
    }

    // MARK: Natural voice

    @ViewBuilder
    private var naturalVoiceRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let download = state.naturalVoiceDownload {
                downloadProgress(download)
            } else if NaturalVoiceInstaller.isInstalled {
                HStack {
                    Text("Which voice")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    naturalVoicePicker
                }
                naturalStatusLine
            } else {
                Text("The natural voice runs on this Mac's Neural Engine, so it doesn't compete with the model that answers your questions. Until it's downloaded, answers use the system voice.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isSnapshot {
                    Button("Download the natural voice (about 310 MB)") {
                        viewModel.downloadNaturalVoice()
                    }
                    .outlinedButton()
                }
                if state.naturalVoiceFailed {
                    Text("That download didn't finish. Answers keep using the system voice in the meantime.")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var naturalVoicePicker: some View {
        if isSnapshot {
            staticValue(NaturalVoiceCatalog.label(for: state.naturalVoiceID))
        } else {
            Picker("", selection: $state.naturalVoiceID) {
                ForEach(NaturalVoiceCatalog.all) { Text($0.label).tag($0.id) }
            }
            .labelsHidden().pickerStyle(.menu).tint(Theme.accent).fixedSize()
        }
    }

    /// Mirrors the shape of `SmartCleanupSettingsSection.statusRow` — a quiet status
    /// line rather than another titled row, because it's ancillary to the picker above.
    @ViewBuilder
    private var naturalStatusLine: some View {
        HStack(spacing: 8) {
            if state.naturalVoiceFailed {
                StatusDot(color: Theme.accent, size: 7)
                Text("Couldn't load the voice — using the system one")
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button("Retry") { state.naturalVoiceRetryRequested = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .pointerCursor()
            } else if state.naturalVoiceReady {
                StatusDot(color: Theme.success, size: 7)
                Text("Voice ready")
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            } else {
                ProgressView().controlSize(.small)
                Text("Warming the voice\u{2026} the first answer may use the system one")
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .font(Typography.caption)
    }

    private func downloadProgress(_ download: ModelInstaller.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(download.detail)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(download.fractionCompleted * 100))%")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            ProgressView(value: download.fractionCompleted)
                .tint(Theme.accent)
        }
    }

    /// `ImageRenderer` can't draw an AppKit `Menu`, so every picker above substitutes
    /// this under `\.isSnapshot`. Same stand-in as `NotesSettingsView`.
    private func staticValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }
}
