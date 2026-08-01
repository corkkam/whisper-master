import SwiftUI

/// The assistant, standing-permission and automation sections of the Connectors page.
///
/// Split out of `ConnectorsSettingsView` to keep that file about connections. These three
/// are all downstream of having connections at all, and each is hidden until it's
/// relevant — an empty "Automations" card on a Mac with no connectors is noise.
struct ConnectorAgentSettings: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var isAddingAutomation = false

    private var store: ConnectorInstanceStore { state.connectorStore }
    private var automations: AutomationStore { state.automationStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            assistantSection
            if !store.grants.isEmpty { permissionsSection }
            if state.connectorAgentEnabled { automationsSection }
        }
        .sheet(isPresented: $isAddingAutomation) {
            AddAutomationSheet(store: automations)
        }
    }

    // MARK: - Assistant

    private var assistantSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Assistant")
            SettingsCard {
                SettingsRow(
                    "Let it use your connectors",
                    subtitle: "Answers run on the same on-device model as Smart cleanup. Nothing leaves this Mac. Off by default."
                ) {
                    ThemeToggle(isOn: $state.connectorAgentEnabled, label: "Connector assistant")
                        .disabled(isSnapshot)
                }
                if state.connectorAgentEnabled {
                    RowDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        // Honest about the model. A 3B sometimes can't produce a usable
                        // answer, and the user should know the fallback exists rather
                        // than wondering why answers vary in richness.
                        Text("It's a small local model, so it won't always manage. When it can't, you get the plain calendar summary instead — never a guess.")
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !state.cleanupModelReady {
                            Text("The model isn't downloaded yet — turn on Smart cleanup to fetch it.")
                                .font(Typography.caption)
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
                RowDivider()
                speechRows
            }
        }
    }

    // MARK: - Reading answers aloud

    /// Speech sits **outside** the `connectorAgentEnabled` branch above: the
    /// deterministic `DaySummaryService` answer is spoken too, so this works whether or
    /// not the user let the model near their connectors.
    @ViewBuilder
    private var speechRows: some View {
        SettingsRow(
            "Read answers aloud",
            subtitle: "Speaks the answer when you ask a question out loud. Uses a voice macOS already has — nothing extra is downloaded."
        ) {
            ThemeToggle(isOn: $state.speakAnswersEnabled, label: "Read answers aloud")
                .disabled(isSnapshot)
        }

        if state.speakAnswersEnabled {
            RowDivider()
            SettingsRow(
                "Also read scheduled answers",
                subtitle: "Automations speak when they fire. Off by default — a Mac that starts talking on its own mid-meeting is a different thing from one that answers you."
            ) {
                ThemeToggle(isOn: $state.speakAutomationAnswersEnabled, label: "Read scheduled answers")
                    .disabled(isSnapshot)
            }
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

    // MARK: - Standing permissions

    /// Every "always allow" the user has granted, with what it actually covers spelled
    /// out. A grant list that only named the tool would hide the part that matters.
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Standing permissions")
                Spacer()
                Text("Revocable any time")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            SettingsCard {
                ForEach(Array(store.grants.sorted { $0.grantedAt > $1.grantedAt }.enumerated()),
                        id: \.element.id) { index, grant in
                    if index > 0 { RowDivider() }
                    grantRow(grant)
                }
            }
        }
    }

    private func grantRow(_ grant: Grant) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ApprovalCopy.verb(for: grant.tool)) \(grant.target)")
                    .font(Typography.sans(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(store.instance(id: grant.instanceID)?.displayLabel ?? "a removed connector")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Revoke") { store.revokeGrant(id: grant.id) }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundStyle(Theme.danger)
                .pointerCursor()
                .disabled(isSnapshot)
        }
        .padding(.vertical, 11)
    }

    // MARK: - Automations

    private var automationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Automations")
                Spacer()
                SecondaryButton(title: "New", icon: "plus") { isAddingAutomation = true }
                    .disabled(isSnapshot || !store.hasReadableCalendar)
            }
            if automations.tasks.isEmpty {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("No automations")
                            .font(Typography.headline).tracking(Typography.headlineTracking)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Ask a question on a schedule — \u{201C}what's on my work calendar\u{201D} every weekday morning. The answer drops into the notch.")
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                }
            } else {
                SettingsCard {
                    ForEach(Array(automations.tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { RowDivider() }
                        automationRow(task)
                    }
                }
            }
            // Stated plainly rather than discovered. A user who expects a 7am digest
            // while their Mac is shut needs to know it won't arrive.
            Text("Automations only run while Whisper Master is open. Anything missed while it was quit runs once when you next open it.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func automationRow(_ task: ScheduledTask) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(task.isEnabled ? Theme.accent : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(Typography.sans(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(task.schedule.human)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                if let lastRun = task.lastRun {
                    Text("Last run \(Self.relative.localizedString(for: lastRun, relativeTo: Date()))\(task.lastStatus == .failed ? " · failed" : "")")
                        .font(Typography.caption)
                        .foregroundStyle(task.lastStatus == .failed ? Theme.danger : Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button("Run now") { viewModel.runAutomationNow(task) }
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.accentText)
                    .pointerCursor()
                    .disabled(isSnapshot)
                ThemeToggle(
                    isOn: Binding(
                        get: { task.isEnabled },
                        set: { automations.setEnabled(task.id, $0) }),
                    label: task.title)
                Button {
                    automations.remove(task.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(isSnapshot)
            }
        }
        .padding(.vertical, 11)
    }

    private static let relative = RelativeDateTimeFormatter()
}

/// Create an automation: a title, a question, and when to ask it.
struct AddAutomationSheet: View {
    let store: AutomationStore

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var question = "what's on my calendar today"
    @State private var cadence: Cadence = .daily
    @State private var hour = 8
    @State private var minute = 0
    @State private var weekday = 2

    enum Cadence: String, CaseIterable, Identifiable {
        case daily, weekly
        var id: String { rawValue }
        var label: String { self == .daily ? "Every day" : "Every week" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New automation")
                .font(Typography.heading(16))
                .foregroundStyle(Theme.textPrimary)

            field("Name", text: $title, placeholder: "Morning briefing")
            field("Ask", text: $question, placeholder: "what's on my work calendar today")

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("When")
                HStack(spacing: 10) {
                    Picker("", selection: $cadence) {
                        ForEach(Cadence.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()

                    if cadence == .weekly {
                        Picker("", selection: $weekday) {
                            ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { index, name in
                                Text(name).tag(index + 1)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }

                    Picker("", selection: $hour) {
                        ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()

                    Picker("", selection: $minute) {
                        ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typography.sans(13))
                    .foregroundStyle(Theme.textSecondary)
                    .pointerCursor()
                PrimaryButton(title: "Create") { save() }
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(WarmBackground())
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Typography.sans(12.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Typography.sans(13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        }
    }

    private func save() {
        let schedule: AutomationSchedule = cadence == .daily
            ? .daily(hour: hour, minute: minute)
            : .weekly(weekday: weekday, hour: hour, minute: minute)
        store.add(ScheduledTask(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: question.trimmingCharacters(in: .whitespacesAndNewlines),
            schedule: schedule))
        dismiss()
    }

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                   "Thursday", "Friday", "Saturday"]

    private static func hourLabel(_ hour: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve) \(suffix)"
    }
}
