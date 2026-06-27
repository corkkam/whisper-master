import SwiftUI

/// History section: counters + the recent-transcripts list with per-row actions.
struct HistorySettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                statCard(value: "\(wordsDictatedToday)", label: "Words dictated today", accent: true)
                statCard(value: "\(state.history.count)", label: "Transcripts saved", accent: false)
            }

            if state.history.isEmpty {
                emptyHistory
            } else {
                HStack {
                    SectionLabel("Recent")
                    Spacer()
                    Button("Clear all") { viewModel.clearAllHistory() }
                        .buttonStyle(.plain)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accent)
                }
                SettingsCard {
                    let entries = Array(state.history.prefix(12))
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        historyRow(entry)
                        if idx < entries.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    private func statCard(value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(Typography.optima(34, .bold))
                .foregroundStyle(accent ? Theme.accent : Theme.textPrimary)
            Text(label)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
        )
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
                iconButton("doc.on.doc", help: "Copy") { viewModel.copyToClipboard(entry.text) }
                iconButton("arrow.up.doc.on.clipboard", help: "Paste at cursor") { viewModel.pasteText(entry.text) }
                iconButton("trash", help: "Delete") { viewModel.deleteHistoryEntry(entry.id) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surfaceSunken)
                )
        }
        .buttonStyle(.plain)
        .help(help)
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
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
        )
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
