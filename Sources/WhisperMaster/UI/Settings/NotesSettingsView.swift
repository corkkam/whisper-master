import SwiftUI

/// Notes & Reminders screen: a search field, dictated voice-note glass cards,
/// and a to-do checklist. All CRUD is local (`NotesStore`).
struct NotesSettingsView: View {
    let notes: NotesStore
    let viewModel: DictationViewModel
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var query = ""
    @State private var editingNote: VoiceNote?
    @State private var newReminder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            searchField

            // Reminders checklist
            VStack(alignment: .leading, spacing: 0) {
                cardHeader(icon: "checklist", title: "Reminders", count: notes.visibleReminders.count)
                addReminderField.padding(.top, 12)
                let items = notes.visibleReminders
                if items.isEmpty {
                    emptyRow("Nothing to do — add a reminder above.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, reminder in
                            reminderRow(reminder)
                            if index < items.count - 1 { RowDivider() }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(20)
            .glassCard()

            // Voice notes
            let matched = notes.notes(matching: query)
            HStack {
                SectionLabel("Voice notes")
                Spacer()
                Text("\(matched.count)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if matched.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(query.isEmpty ? "No notes yet." : "No notes match \u{201C}\(query)\u{201D}.")
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Dictate something and save it here to keep it around.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .glassCard()
            } else {
                ForEach(matched) { note in
                    noteCard(note)
                }
            }
        }
        .sheet(item: $editingNote) { note in
            NoteEditorSheet(note: note, notes: notes) { editingNote = nil }
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            if isSnapshot {
                Text("Search notes…").font(Typography.body).foregroundStyle(Theme.textTertiary)
            } else {
                TextField("Search notes…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: 12, tint: 0.4)
    }

    // MARK: Reminders

    @ViewBuilder
    private var addReminderField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
            if isSnapshot {
                Text("New reminder…").font(Typography.body).foregroundStyle(Theme.textTertiary)
            } else {
                TextField("New reminder…", text: $newReminder)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .onSubmit(commitReminder)
            }
            Spacer(minLength: 0)
            Button("Add", action: commitReminder)
                .buttonStyle(GhostButtonStyle())
                .disabled(newReminder.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
    }

    private func commitReminder() {
        let text = newReminder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.addReminder(title: text)
        newReminder = ""
    }

    private func reminderRow(_ reminder: TodoReminder) -> some View {
        HStack(spacing: 12) {
            Button { notes.toggleReminder(reminder.id) } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(reminder.isCompleted ? Theme.accent : Theme.textTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(reminder.title)
                .font(Typography.body)
                .foregroundStyle(reminder.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(reminder.isCompleted, color: Theme.textTertiary)
            Spacer(minLength: 8)
            Button { notes.deleteReminder(reminder.id) } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 11)
    }

    // MARK: Notes

    private func noteCard(_ note: VoiceNote) -> some View {
        Button { editingNote = note } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.displayTitle)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text(Self.timestamp(note.updatedAt))
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(note.body)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { notes.deleteNote(note.id) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Shared

    private func cardHeader(icon: String, title: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(title).font(Typography.title).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text("\(count)").font(Typography.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Typography.body)
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 14)
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

/// A modal editor for a voice note — edit title + body, or delete.
private struct NoteEditorSheet: View {
    let note: VoiceNote
    let notes: NotesStore
    let dismiss: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var title: String
    @State private var body_: String

    init(note: VoiceNote, notes: NotesStore, dismiss: @escaping () -> Void) {
        self.note = note
        self.notes = notes
        self.dismiss = dismiss
        _title = State(initialValue: note.title)
        _body_ = State(initialValue: note.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit note")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)

            if isSnapshot {
                Text(title.isEmpty ? "Title" : title).font(Typography.headline)
                Text(body_).font(Typography.body).foregroundStyle(Theme.textSecondary)
            } else {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(Typography.headline)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke, lineWidth: 1))
                TextEditor(text: $body_)
                    .font(Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 160)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke, lineWidth: 1))
            }

            HStack {
                Button(role: .destructive) {
                    notes.deleteNote(note.id)
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
                SecondaryButton(title: "Cancel", action: dismiss)
                PrimaryButton(title: "Save") {
                    notes.updateNote(note.id, title: title, body: body_)
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(WarmBackground())
    }
}
