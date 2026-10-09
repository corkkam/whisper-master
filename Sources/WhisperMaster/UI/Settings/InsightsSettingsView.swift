import SwiftUI

/// Insights sub-page: your dictation, by the numbers. All derived from the
/// locally-kept transcript history — no tracking, no backend.
struct InsightsSettingsView: View {
    @Bindable var state: AppState

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: columns, spacing: 14) {
                StatTile(value: "\(state.history.count)", label: "Transcripts kept", icon: "text.quote")
                StatTile(value: "\(totalWords)", label: "Words dictated", icon: "textformat.size")
                StatTile(value: "\(thisWeek)", label: "This week", icon: "calendar")
                StatTile(value: "\(averageWords)", label: "Avg words each", icon: "chart.bar")
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text("Most recent").font(Typography.title).foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.bottom, 4)
                if state.history.isEmpty {
                    Text("Nothing dictated yet.")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 12)
                } else {
                    VStack(spacing: 0) {
                        let recent = Array(state.history.prefix(5))
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 12) {
                                Text(entry.preview)
                                    .font(Typography.body)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 10)
                                Text(Self.time(entry.createdAt))
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.vertical, 11)
                            if index < recent.count - 1 { RowDivider() }
                        }
                    }
                }
            }
            .padding(20)
            .glassCard()
        }
    }

    private var totalWords: Int {
        state.history.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private var thisWeek: Int {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return state.history.filter { $0.createdAt >= cutoff }.count
    }

    private var averageWords: Int {
        guard !state.history.isEmpty else { return 0 }
        return totalWords / state.history.count
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: date)
    }
}
