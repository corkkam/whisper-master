import SwiftUI

/// The quick-actions band: what the notch holds when you rest the pointer on it.
///
/// Two columns — **today**, as one ordered run of events and reminders
/// interleaved by time, and the **notes** you pinned or touched last — over a
/// row of the three things you'd otherwise open the window for. It is a *glance plus
/// one tap*, not a second Notes app: three rows a column, one action each, and the
/// only mutation available inline is ticking a reminder off — and back on, since a
/// bezel panel has no undo affordance of its own (the one action that
/// needs no typing). Anything that needs a keyboard hands off to the real window,
/// because this is a non-activating panel on the bezel and text has no business here.
///
/// Same molded `NotchShape`, same pinned-ink treatment as the dictation surface and
/// the onboarding band; `.onDarkSurface()` at the root is what puts the button ladder
/// on `Theme.Notch` tokens.
struct NotchQuickActionsView: View {
    let model: NotchQuickActionsModel
    var geometry: NotchGeometry = .none
    var layout: NotchQuickActionsLayout = NotchQuickActionsLayout()
    /// Opens Settings → Notes & Reminders, optionally straight into a fresh editor.
    var onOpenNotes: (NotesComposerRequest?) -> Void = { _ in }
    /// Opens the Settings window — the gear in the header row.
    var onOpenSettings: () -> Void = {}
    /// Opens a meeting's conference link. Injected so the view stays AppKit-free,
    /// same as the dictation surface's.
    var onJoin: (URL) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = NotchShape(
            topConcaveRadius: layout.topConcaveRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        )

        VStack(spacing: 0) {
            // Camera dead-zone — nothing renders behind the physical notch. Hittable
            // here (unlike the dictation surface): the pointer resting on the notch
            // is what holds this panel open, so the strip it rests on has to count.
            Color.clear
                .frame(height: geometry.notchHeight)

            band
                .frame(height: layout.thickness(rows: model.visibleRowCount))
        }
        .frame(width: layout.surfaceWidth(for: geometry), alignment: .top)
        .background { shape.fill(Theme.Notch.surface) }
        .clipShape(shape)
        .onDarkSurface()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
    }

    // MARK: - Band

    private var band: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                // Resolved once per render into a local, so every row in a frame
                // agrees about what "now" is — five rows each calling `Date()`
                // would be five slightly different days.
                let instant = Date()
                let day = model.day(at: instant)
                NotchDayTimelineColumn(
                    rows: day.rows,
                    hidden: day.hidden,
                    now: instant,
                    isChecked: { model.isChecked($0) },
                    onToggle: { model.toggle($0) },
                    onJoin: onJoin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                column(
                    title: model.showsPinned ? "Pinned & recent" : "Recent notes",
                    isEmpty: model.recentNotes.isEmpty,
                    emptyLine: "No notes yet."
                ) {
                    ForEach(model.recentNotes) { note in
                        NoteQuickRow(
                            note: note,
                            onOpen: { onOpenNotes(nil) },
                            onUnpin: { model.unpin(note) })
                    }
                }
                // Fixed, and narrower than the day: the notes column is what you
                // *also* get, and letting it take half the band made a five-row day
                // wrap while three note titles sat in white space.
                .frame(width: layout.notesColumnWidth)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.md)
        .padding(.horizontal, Theme.Space.lg)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Quick actions")
                .font(Typography.notchTitle)
                .foregroundStyle(Theme.Notch.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.sm)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .iconButton(size: 22, tooltip: "Open Settings")
            .accessibilityLabel("Open Settings")
        }
    }

    /// One column: a quiet label over up to three rows, or a single honest line when
    /// there's nothing in it. Both columns keep the same width so the band reads as
    /// two halves rather than as one list that overflowed.
    @ViewBuilder
    private func column<Rows: View>(
        title: String,
        isEmpty: Bool,
        emptyLine: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(Typography.notchCaption)
                .tracking(0.6)
                .foregroundStyle(Theme.Notch.textTertiary)
            if isEmpty {
                Text(emptyLine)
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.textSecondary)
            } else {
                rows()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.sm) {
            QuickActionButton(title: "New reminder", icon: "bell.badge") {
                onOpenNotes(.reminder)
            }
            QuickActionButton(title: "New note", icon: "square.and.pencil") {
                onOpenNotes(.note)
            }
            Spacer(minLength: Theme.Space.sm)
            QuickActionButton(title: "Open all", icon: "arrow.up.forward") {
                onOpenNotes(nil)
            }
        }
    }
}

// MARK: - Rows

/// A note at a glance. Tapping it opens the real editor — the band has no business
/// holding a text field.
///
/// A **pinned** note wears the pin glyph in ember and carries an unpin affordance, so
/// the surface that shows a pin also offers the way to take it off. A note is pinned
/// *to* the notch, so being unable to unpin it from the notch would mean walking to
/// the window to undo something the notch is the whole point of.
private struct NoteQuickRow: View {
    let note: Note
    let onOpen: () -> Void
    var onUnpin: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onOpen) {
                HStack(spacing: 7) {
                    Image(systemName: note.isPinned ? "pin.fill" : "text.alignleft")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(note.isPinned ? Theme.Notch.accent : Theme.Notch.textTertiary)
                    Text(note.displayTitle)
                        .font(Typography.notchBody)
                        .foregroundStyle(Theme.Notch.text)
                        .lineLimit(1)
                    // A spoken note says so — the recording is the thing that makes
                    // it verifiable, and the glyph is how you know there is one
                    // before you open the window.
                    if note.hasAudio {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Notch.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(note.isPinned
                ? "Open pinned note “\(note.displayTitle)”"
                : "Open note “\(note.displayTitle)”")

            if note.isPinned, isHovering {
                Button(action: onUnpin) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 10, weight: .semibold))
                }
                .iconButton(size: 18, tooltip: "Unpin from the notch")
                .accessibilityLabel("Unpin “\(note.displayTitle)” from the notch")
            }
        }
        .onHover { isHovering = $0 }
    }
}

/// The band's action rung: a compact labelled pill on the ink surface. Outlined
/// rather than filled — three equal-weight ways out of the panel, none of them the
/// one true action, so none of them gets the ember pill.
private struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(Typography.sans(12, .semibold))
            }
        }
        .outlinedButton()
        .accessibilityLabel(title)
    }
}

// MARK: - Formatting

/// Due-date wording for the band, which has room for three words, not a sentence:
/// "9:30 AM" today, "Tomorrow 9:30 AM", "Mon 9:30 AM" inside the week, a date
/// beyond it, and "Overdue" once it's past.
enum NotchQuickActionsFormat {
    static func due(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if date <= now { return "Overdue" }
        let time = timeFormatter.string(from: date)
        // ⚠️ Today/tomorrow must be judged against `now`, not the ambient clock.
        // `Calendar.isDateInToday` / `isDateInTomorrow` resolve against `Date()`
        // internally and ignore an injected `now` entirely, so this function used
        // to mix two different "nows" — these two branches read the system clock
        // while the `days` branch below read `now`. In production the two agree
        // (`now` defaults to `Date()`), which is why the bug never surfaced to
        // users; what it did do was make `testTomorrowIsNamed` pass only on the
        // one day it was written and fail every day afterwards.
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        let days = calendar.dateComponents([.day], from: now, to: date).day ?? 0
        if days < 7 { return "\(weekdayFormatter.string(from: date)) \(time)" }
        return dayFormatter.string(from: date)
    }

    // These render in the *current* time zone regardless of the `calendar` passed
    // to `due` — deliberate, and not the bug fixed above. Production always passes
    // `.current`, so the two agree; a test injecting a UTC calendar gets UTC day
    // boundaries with locally-formatted clock times, which is why assertions here
    // should check the branch taken ("Tomorrow …") rather than an exact time string.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()
}
