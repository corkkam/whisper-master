import AppKit
import SwiftUI

/// The "Notes & Reminders" tab: freeform notes plus time-based reminders that
/// alert as a notification or a looping alarm. Per-account, synced across Macs
/// (see `NotesStore` / `NotesSyncClient`). Alert style + sound have global
/// defaults here and a per-reminder override in the editor.
struct NotesSettingsView: View {
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    /// Non-nil drafts drive the editor sheets. A fresh item = "add"; an existing
    /// one = "edit" (same id, so `upsert` replaces it).
    @State private var reminderDraft: ReminderItem?
    @State private var noteDraft: Note?

    private var store: NotesStore { state.notesStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            spokenCommandsSection
            remindersSection
            notesSection
            alertDefaultsSection
        }
        // A "New note" / "New reminder" tap from the notch quick-actions band opens
        // the editor here — that panel is a non-activating band on the bezel, so it
        // can't host a text field of its own. One-shot: cleared as it's consumed.
        .onAppear { consumeComposerRequest(state.requestedNotesComposer) }
        .onChange(of: state.requestedNotesComposer) { _, request in
            consumeComposerRequest(request)
        }
        .sheet(item: $reminderDraft) { draft in
            ReminderEditor(
                reminder: draft,
                onSave: { store.upsertReminder($0); reminderDraft = nil },
                onCancel: { reminderDraft = nil }
            )
        }
        .sheet(item: $noteDraft) { draft in
            NoteEditor(
                note: draft,
                onSave: { store.upsertNote($0); noteDraft = nil },
                onCancel: { noteDraft = nil }
            )
        }
    }

    /// Open a fresh editor for a request that came from outside this view, then
    /// clear it so a later navigation back here doesn't re-open the sheet.
    private func consumeComposerRequest(_ request: NotesComposerRequest?) {
        guard let request, !isSnapshot else { return }
        state.requestedNotesComposer = nil
        switch request {
        case .note:
            noteDraft = Note()
        case .reminder:
            reminderDraft = ReminderItem(
                dueDate: Date().addingTimeInterval(3_600),
                alertStyle: state.reminderDefaultAlertStyle,
                soundName: state.reminderDefaultSound)
        }
    }

    // MARK: - Spoken commands

    /// How to reach the assistant by voice. **Not a toggle** — the feature is the
    /// held chord itself, so there is nothing to switch on: hold it and the words go
    /// to the assistant, don't and they're typed like any other dictation. This
    /// section exists purely so the shortcut is discoverable.
    private var spokenCommandsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Talk to the assistant")
            SettingsCard {
                SettingsRow("Say it instead of typing it",
                            subtitle: "Hold the keys and speak — “take a note that the wifi password is…”, “remind me to call mom tomorrow”, “what's on my calendar?”. Let go and it's handled instead of typed: notes and reminders land here, questions are answered in the notch. Reminders with no stated time get a default you can tap to change.") {
                    keyCap(ModifierChord.command.compactName)
                }
            }
        }
    }

    /// Static key-cap label for a fixed shortcut — the same chrome the hotkey
    /// pickers wear, without the picker (this chord isn't user-configurable).
    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .accessibilityLabel("Shortcut: \(ModifierChord.command.displayName)")
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Reminders")
                Spacer()
                SecondaryButton(title: "Add reminder", icon: "plus") {
                    reminderDraft = ReminderItem(
                        dueDate: Date().addingTimeInterval(3_600),
                        alertStyle: state.reminderDefaultAlertStyle,
                        soundName: state.reminderDefaultSound)
                }
                .disabled(isSnapshot)
            }

            let reminders = store.visibleReminders
            if reminders.isEmpty {
                emptyCard("No reminders yet", "Add one and Whisper Master will nudge you at the right time.")
            } else {
                SettingsCard {
                    ForEach(Array(reminders.enumerated()), id: \.element.id) { index, reminder in
                        if index > 0 { RowDivider() }
                        reminderRow(reminder)
                    }
                }
            }
        }
    }

    private func reminderRow(_ reminder: ReminderItem) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(reminder.displayTitle)
                        .font(Typography.headline).tracking(Typography.headlineTracking)
                        .foregroundStyle(reminder.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(reminder.isCompleted)
                    if reminder.repeatRule != .none {
                        Image(systemName: "repeat")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(Self.dueFormatter.string(from: reminder.dueDate))
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    Chip(reminder.alertStyle.displayName)
                    Chip(ReminderSound.label(for: reminder.soundName))
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if !reminder.isCompleted {
                    IconButton("checkmark.circle", label: "Mark done") { store.completeReminder(reminder.id) }
                }
                IconButton("pencil", label: "Edit reminder") { reminderDraft = reminder }
                IconButton("trash", label: "Delete reminder", role: .destructive) { store.deleteReminder(reminder.id) }
            }
        }
        .padding(.vertical, 15)
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Notes")
                Spacer()
                SecondaryButton(title: "Add note", icon: "plus") {
                    noteDraft = Note()
                }
                .disabled(isSnapshot)
            }

            let notes = store.visibleNotes
            if notes.isEmpty {
                emptyCard("No notes yet", "Keep quick thoughts here — they sync to your account.")
            } else {
                SettingsCard {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 { RowDivider() }
                        noteRow(note)
                    }
                }
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.displayTitle)
                    .font(Typography.headline).tracking(Typography.headlineTracking)
                    .foregroundStyle(Theme.textPrimary)
                if !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note.body)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                IconButton("pencil", label: "Edit note") { noteDraft = note }
                IconButton("trash", label: "Delete note", role: .destructive) { store.deleteNote(note.id) }
            }
        }
        .padding(.vertical, 15)
    }

    // MARK: - Alert defaults

    private var alertDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Alert defaults")
            SettingsCard {
                SettingsRow("Default alert style",
                            subtitle: "New reminders use this. \"Loud alarm\" rings until you dismiss it; \"Notification\" is a single banner.") {
                    alertStylePicker
                }
                RowDivider()
                SettingsRow("Default sound",
                            subtitle: "The sound new reminders play.") {
                    HStack(spacing: 8) {
                        soundPicker
                        IconButton("play.circle", label: "Test sound") {
                            NotesSettingsView.preview(state.reminderDefaultSound)
                        }
                        .disabled(isSnapshot)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var alertStylePicker: some View {
        if isSnapshot {
            staticValue(state.reminderDefaultAlertStyle.displayName)
        } else {
            Picker("", selection: $state.reminderDefaultAlertStyle) {
                ForEach(ReminderAlertStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).tint(Theme.accent).fixedSize()
        }
    }

    @ViewBuilder
    private var soundPicker: some View {
        if isSnapshot {
            staticValue(ReminderSound.label(for: state.reminderDefaultSound))
        } else {
            Picker("", selection: $state.reminderDefaultSound) {
                ForEach(ReminderSound.names, id: \.self) { Text(ReminderSound.label(for: $0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).tint(Theme.accent).fixedSize()
        }
    }

    // MARK: - Helpers

    private func emptyCard(_ title: String, _ subtitle: String) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Typography.headline).tracking(Typography.headlineTracking).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(Typography.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
    }

    private func staticValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }

    /// Play a system sound once as a preview (nil-safe, restart-safe).
    static func preview(_ name: String) {
        let sound = NSSound(named: NSSound.Name(ReminderSound.resolved(name)))
        sound?.stop()
        sound?.play()
    }

    static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

// MARK: - Reminder editor

/// The add/edit reminder sheet. Keeps its own draft copy so Cancel discards.
private struct ReminderEditor: View {
    @State private var draft: ReminderItem
    let onSave: (ReminderItem) -> Void
    let onCancel: () -> Void

    init(reminder: ReminderItem, onSave: @escaping (ReminderItem) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: reminder)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Reminder").font(Typography.title).tracking(Typography.titleTracking).foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                fieldLabel("Title")
                TextField("What should I remind you about?", text: $draft.title)
                    .textFieldStyle(.roundedBorder)

                fieldLabel("Notes (optional)")
                TextField("Details", text: $draft.body, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                fieldLabel("When")
                DatePicker("", selection: $draft.dueDate, in: Date()...)
                    .labelsHidden().datePickerStyle(.compact)

                HStack(spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Alert")
                        Picker("", selection: $draft.alertStyle) {
                            ForEach(ReminderAlertStyle.allCases) { Text($0.displayName).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).tint(Theme.accent).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Repeat")
                        Picker("", selection: $draft.repeatRule) {
                            ForEach(ReminderRepeat.allCases) { Text($0.displayName).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).tint(Theme.accent).fixedSize()
                    }
                }

                fieldLabel("Sound")
                HStack(spacing: 8) {
                    Picker("", selection: $draft.soundName) {
                        ForEach(ReminderSound.names, id: \.self) { Text(ReminderSound.label(for: $0)).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).tint(Theme.accent).fixedSize()
                    IconButton("play.circle", label: "Test sound") { NotesSettingsView.preview(draft.soundName) }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                SecondaryButton(title: "Cancel", action: onCancel)
                PrimaryButton(title: "Save", icon: "checkmark") { onSave(draft) }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460, height: 460)
        .background(WarmBackground())
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(Typography.label).tracking(1.4).foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - Note editor

private struct NoteEditor: View {
    @State private var draft: Note
    let onSave: (Note) -> Void
    let onCancel: () -> Void

    init(note: Note, onSave: @escaping (Note) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: note)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Note").font(Typography.title).tracking(Typography.titleTracking).foregroundStyle(Theme.textPrimary)

            TextField("Title (optional)", text: $draft.title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $draft.body)
                .font(Typography.body)
                .frame(minHeight: 180)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

            HStack {
                Spacer()
                SecondaryButton(title: "Cancel", action: onCancel)
                PrimaryButton(title: "Save", icon: "checkmark") { onSave(draft) }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty
                        && draft.body.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460, height: 380)
        .background(WarmBackground())
    }
}
