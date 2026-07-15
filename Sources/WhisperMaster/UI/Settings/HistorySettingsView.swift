import SwiftUI

/// History section: counters + the recent-transcripts list with per-row actions.
struct HistorySettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    /// The list shows a capped preview until the user asks for the whole set, so
    /// a full 50-entry history doesn't dominate the page — but every saved entry
    /// is reachable, so the count on the "Transcripts saved" tile is honest.
    @State private var showAll = false
    /// Per-row delete goes through a confirmation, so does "Clear all".
    @State private var pendingDelete: TranscriptHistoryEntry?
    @State private var confirmClearAll = false

    private let previewLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: Theme.Space.lg) {
                StatTile(value: "\(wordsDictatedToday)",
                         label: "Words dictated today",
                         valueColor: Theme.accent)
                StatTile(value: "\(state.history.count)",
                         label: "Transcripts saved")
            }

            if state.history.isEmpty {
                emptyHistory
            } else {
                HStack {
                    SectionLabel("Recent")
                    Spacer()
                    Button("Clear all") { confirmClearAll = true }
                        .buttonStyle(.plain)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.danger)
                }
                SettingsCard {
                    let entries = showAll ? state.history : Array(state.history.prefix(previewLimit))
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        historyRow(entry)
                        if idx < entries.count - 1 { RowDivider() }
                    }
                }
                if !showAll, state.history.count > previewLimit {
                    Button("Show all \(state.history.count) transcripts") { showAll = true }
                        .buttonStyle(.plain)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
            }
        }
        .confirmationDialog(
            "Clear all transcripts?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) { viewModel.clearAllHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(state.history.count) saved transcripts and can't be undone.")
        }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                viewModel.deleteHistoryEntry(entry.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func historyRow(_ entry: TranscriptHistoryEntry) -> some View {
        let engine = TranscriberEngine(rawValue: entry.engineRawValue)
        let words = entry.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        return HStack(alignment: .top, spacing: 16) {
            Text(Self.timeFormatter.string(from: entry.createdAt))
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.text)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text("\(words) words")
                        .foregroundStyle(Theme.textTertiary)
                    if let engine {
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text(engine.displayName)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(Typography.caption)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                IconButton("doc.on.doc", label: "Copy transcript") { viewModel.copyToClipboard(entry.text) }
                IconButton("arrow.up.doc.on.clipboard", label: "Paste at cursor") { viewModel.pasteText(entry.text) }
                IconButton("trash", label: "Delete transcript", role: .destructive) { pendingDelete = entry }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var emptyHistory: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("No transcripts yet")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)
            Text("Hold your push-to-talk key and dictate. Finished transcripts land here, ready to paste again.")
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(44)
        .card()
    }

    private var wordsDictatedToday: Int {
        let calendar = Calendar.current
        return state.history
            .filter { calendar.isDateInToday($0.createdAt) }
            .reduce(0) { $0 + $1.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}
