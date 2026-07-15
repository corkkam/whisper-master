import SwiftUI

/// Insights section: the "at a glance" dashboard — a headline WPM gauge, a fixes
/// tally, a lifetime word count with a playful local comparison, then a per-app
/// usage breakdown and a GitHub-style streak heatmap. Every number comes from
/// `state.usageStore`; every shape is hand-drawn SwiftUI (no `Charts` import —
/// that framework breaks the ImageRenderer snapshot loop).
struct InsightsSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    /// One newline-free convenience handle to the store.
    private var usage: UsageStore { state.usageStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if usage.totalDictations == 0 {
                emptyState
            } else {
                // Top row — three KPI tiles of equal width.
                HStack(alignment: .top, spacing: Theme.Space.lg) {
                    wpmCard
                    fixesCard
                    totalWordsCard
                }
                // Bottom row — two wider cards.
                HStack(alignment: .top, spacing: Theme.Space.lg) {
                    appUsageCard
                    streakCard
                }
            }
        }
    }

    // MARK: - Top row: WPM

    private var wpmCard: some View {
        // A hand-drawn half-circle gauge as the tile's top-right accessory: a
        // faint full arc with the accent arc filled proportionally. Caps at
        // 200 wpm so a burst can't overrun it.
        StatTile(value: "\(usage.recentWpm)",
                 label: "words per minute",
                 valueColor: Theme.accent) {
            GaugeArc(progress: min(1, Double(usage.recentWpm) / 200))
                .frame(width: 76, height: 34)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Top row: Fixes made

    private var fixesCard: some View {
        let fixes = usage.totalFixes
        return StatTile(value: "\(fixes.total)",
                        label: "fixes made",
                        caption: "\(fixes.wordsCorrected) words corrected\n\(fixes.dictionary) dictionary fixes")
            .frame(maxHeight: .infinity)
    }

    // MARK: - Top row: Total words dictated

    private var totalWordsCard: some View {
        StatTile(value: "\(usage.totalWords)",
                 label: "total words dictated",
                 caption: bookComparison)
            .frame(maxHeight: .infinity)
    }

    /// A charming, entirely local comparison: a paperback runs ~250 words a page,
    /// a typical novel ~90k words. Frame the lifetime count against whichever
    /// reads best so the number feels earned rather than abstract.
    private var bookComparison: String {
        let words = usage.totalWords
        let novelWords = 90_000
        if words >= novelWords {
            let books = Double(words) / Double(novelWords)
            return String(format: "that's about %.1f novels' worth of words 📚", books)
        }
        let pages = max(1, words / 250)
        return "that's about \(pages) \(pages == 1 ? "page" : "pages") of a paperback 📖"
    }

    // MARK: - Bottom row: App usage

    private var appUsageCard: some View {
        let apps = usage.topApps()
        return wideCard {
            cardHeader(title: "App usage", statLabel: "Total apps used", statValue: usage.totalAppsUsed)
            if apps.isEmpty {
                Text("No apps tracked yet.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(apps.enumerated()), id: \.element.bundleID) { idx, entry in
                        // Fade the bars down the list so the ranking reads top-down;
                        // clamp so the tail still has enough ink to see.
                        appBar(
                            name: entry.usage.name.isEmpty ? entry.bundleID : entry.usage.name,
                            words: entry.usage.words,
                            share: entry.share,
                            opacity: max(0.4, 1 - Double(idx) * 0.13))
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// One app's horizontal % bar: a hand-drawn capsule track with an accent
    /// capsule filled to `share` (0…1), modeled on `RecordingLevelBadge`'s capsules.
    private func appBar(name: String, words: Int, share: Double, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(words) · \(Int((share * 100).rounded()))%")
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule()
                        .fill(Theme.accent.opacity(opacity))
                        // Floor the width so a tiny share still shows a nub.
                        .frame(width: max(6, geo.size.width * CGFloat(share)))
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Bottom row: Streak + heatmap

    private var streakCard: some View {
        wideCard {
            cardHeader(
                title: "\(usage.currentStreak) day streak",
                statLabel: "Longest streak",
                statValue: usage.longestStreak)
            HeatmapGrid(usage: usage)
                .padding(.top, 6)
            heatmapLegend
                .padding(.top, 8)
        }
    }

    private var heatmapLegend: some View {
        HStack(spacing: 5) {
            Text("Less")
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textTertiary)
            ForEach(0..<5, id: \.self) { bucket in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(HeatmapGrid.color(forBucket: bucket))
                    .frame(width: 10, height: 10)
            }
            Text("More")
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Reusable card chrome

    /// The wider bottom cards reuse the shared `SettingsCard` chrome (fill, border,
    /// soft shadow) with all-around padding.
    private func wideCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        SettingsCard(boxed: true, contentPadding: 20) {
            VStack(alignment: .leading, spacing: 0) {
                content()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A card header: a title on the left and a small right-aligned stat readout
    /// ("LABEL | value"), matching the reference mockup.
    private func cardHeader(title: String, statLabel: String, statValue: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Text(statLabel.uppercased())
                    .font(Typography.sans(9.5, .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textTertiary)
                Text("\(statValue)")
                    .font(Typography.sans(15, .bold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("No insights yet")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)
            Text("Start dictating and this page fills up — your speed, the words you've saved, the apps you use most, and a streak worth keeping.")
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(44)
        .card()
    }
}

// MARK: - Gauge arc

/// A flat-bottomed half-circle gauge. The faint track is a full semicircle; the
/// accent stroke fills the left→right sweep in proportion to `progress` (0…1).
private struct GaugeArc: View {
    let progress: Double

    var body: some View {
        ZStack {
            ArcShape(progress: 1)
                .stroke(Theme.surfaceSunken, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            ArcShape(progress: max(0, min(1, progress)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct ArcShape: Shape {
        let progress: Double
        func path(in rect: CGRect) -> Path {
            var path = Path()
            // Center on the bottom edge so the arc bulges upward. In SwiftUI's
            // y-down space, sweeping 180°→360° traces left → top → right.
            let radius = min(rect.width / 2, rect.height) - 4
            let center = CGPoint(x: rect.midX, y: rect.maxY - 2)
            path.addArc(
                center: center,
                radius: max(1, radius),
                startAngle: .degrees(180),
                endAngle: .degrees(180 + 180 * progress),
                clockwise: false)
            return path
        }
    }
}

// MARK: - Heatmap

/// A GitHub-style contribution grid: 17 week columns × 7 day rows (Sun→Sat),
/// each square shaded by that day's word count. Days are keyed via
/// `StreakCalculator.dayKey` so intensity lines up exactly with the rollups.
private struct HeatmapGrid: View {
    let usage: UsageStore

    private let weeks = 17
    private let square: CGFloat = 10
    private let spacing: CGFloat = 2.5

    var body: some View {
        let days = weekColumns()
        let maxWords = max(1, days.flatMap { $0 }.map { $0.words }.max() ?? 0)
        HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, week in
                VStack(spacing: spacing) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(cell.isFuture ? Color.clear : Self.color(forWords: cell.words, max: maxWords))
                            .frame(width: square, height: square)
                    }
                }
            }
        }
    }

    private struct Cell {
        let words: Int
        let isFuture: Bool
    }

    /// Walk back to the Sunday that starts the window, then lay out each week as
    /// a column of 7 days. Days after today are marked `isFuture` (blank).
    private func weekColumns() -> [[Cell]] {
        let calendar = Calendar.current
        let today = Date()
        // Start of the current week (Sunday, per the default en_US calendar).
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        guard let firstSunday = calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: weekStart) else {
            return []
        }
        var columns: [[Cell]] = []
        for col in 0..<weeks {
            var column: [Cell] = []
            for row in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: col * 7 + row, to: firstSunday) else {
                    column.append(Cell(words: 0, isFuture: true))
                    continue
                }
                let isFuture = date > today
                let words = isFuture ? 0 : usage.words(onDayKey: StreakCalculator.dayKey(for: date, calendar: calendar))
                column.append(Cell(words: words, isFuture: isFuture))
            }
            columns.append(column)
        }
        return columns
    }

    // MARK: Color scale

    /// Map a day's word count to one of five buckets against the window max, then
    /// to a color: bucket 0 is the faint sunken surface, 1…4 deepen the accent.
    static func color(forWords words: Int, max maxWords: Int) -> Color {
        guard words > 0 else { return color(forBucket: 0) }
        // Fraction of the busiest day, bucketed into 4 accent levels.
        let fraction = Double(words) / Double(max(1, maxWords))
        let bucket = min(4, 1 + Int(fraction * 3.999))
        return color(forBucket: bucket)
    }

    /// Buckets 0…4: 0 is the empty-day swatch, 1…4 ramp the accent opacity.
    static func color(forBucket bucket: Int) -> Color {
        switch bucket {
        case 0: return Theme.surfaceSunken
        case 1: return Theme.accent.opacity(0.28)
        case 2: return Theme.accent.opacity(0.5)
        case 3: return Theme.accent.opacity(0.75)
        default: return Theme.accent
        }
    }
}
