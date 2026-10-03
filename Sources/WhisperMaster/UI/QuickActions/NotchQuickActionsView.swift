import SwiftUI

/// The quick-actions band: what the notch holds when you rest the pointer on it.
///
/// **One tab bar, one page at a time.** Today and Notes are fixed; each connection
/// the user pinned on the Connectors page adds a tab of its own with its live count;
/// the gear is the Settings tab. It reopens on the tab used last. Every page stays a
/// *glance plus one tap*, not a second app: a handful of rows, one action each, and
/// the only mutations available inline are the ones that need no typing — ticking a
/// reminder (both ways), unpinning, and the Settings tab's switches. Anything that
/// needs a keyboard hands off to the real window, because this is a non-activating
/// panel on the bezel and text has no business here.
///
/// Tabs change on a **click**, never on hover: the pointer crosses the tab bar on
/// its way down into the band, and a bar that switched under it would land you on
/// whichever tab you happened to pass last.
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
    /// Opens the main window on a section — Connectors for "+" and a repair, the
    /// Settings page for "All settings".
    var onOpenSettings: (SettingsSection) -> Void = { _ in }
    /// Opens a meeting's conference link. Injected so the view stays AppKit-free,
    /// same as the dictation surface's.
    var onJoin: (URL) -> Void = { _ in }
    /// Opens a connector item or the connector's own app. The window checks it
    /// against `NotchConnectorLinks.isOpenable` before handing it to the system.
    var onOpenLink: (URL) -> Void = { _ in }

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
                .frame(height: layout.thickness(rows: model.visibleRowCount, captioned: model.isCaptioned))
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
        let tab = model.currentTab
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            NotchQuickActionsTabBar(model: model, onAddPin: { onOpenSettings(.connectors) })
            Group {
                switch tab {
                case .today: todayPage
                case .notes: notesPage
                case .connector(let id): connectorPage(id)
                case .settings: settingsPage
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            footer(for: tab)
        }
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.md)
        .padding(.horizontal, Theme.Space.lg)
    }

    // MARK: - Pages

    private var todayPage: some View {
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
    }

    @ViewBuilder
    private var notesPage: some View {
        let notes = model.notesTabNotes
        if notes.isEmpty {
            NotchQuietLine("No notes yet.")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(notes) { note in
                    NoteQuickRow(
                        note: note,
                        showsAge: true,
                        onOpen: { onOpenNotes(nil) },
                        onUnpin: { model.unpin(note) })
                }
            }
        }
    }

    @ViewBuilder
    private func connectorPage(_ id: UUID) -> some View {
        if let instance = model.state.connectorStore.instance(id: id) {
            NotchConnectorPage(
                instance: instance,
                content: model.connectorContent(id),
                isLoading: model.feed.entry(for: id)?.isLoading ?? false,
                onOpenLink: onOpenLink,
                onJoin: onJoin)
        }
    }

    private var settingsPage: some View {
        NotchSettingsPage(state: model.state)
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(for tab: NotchQuickActionsTab) -> some View {
        HStack(spacing: Theme.Space.sm) {
            switch tab {
            case .today:
                QuickActionButton(title: "New reminder", icon: "bell.badge") { onOpenNotes(.reminder) }
                QuickActionButton(title: "New note", icon: "square.and.pencil") { onOpenNotes(.note) }
                Spacer(minLength: Theme.Space.sm)
                QuickActionButton(title: "Open all", icon: "arrow.up.forward") { onOpenNotes(nil) }
            case .notes:
                QuickActionButton(title: "New note", icon: "square.and.pencil") { onOpenNotes(.note) }
                QuickActionButton(title: "New reminder", icon: "bell.badge") { onOpenNotes(.reminder) }
                Spacer(minLength: Theme.Space.sm)
                QuickActionButton(title: "All notes", icon: "arrow.up.forward") { onOpenNotes(nil) }
            case .connector(let id):
                connectorFooter(id)
            case .settings:
                QuickActionButton(title: "All settings", icon: "arrow.up.forward") { onOpenSettings(.settings) }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func connectorFooter(_ id: UUID) -> some View {
        if let instance = model.state.connectorStore.instance(id: id) {
            // A connection that needs the user gets the way to fix it, not a link
            // into an app that will show them the same failure.
            if !instance.isEnabled || !NotchConnectorFeed.shouldRead(instance) {
                QuickActionButton(title: "Open Connectors", icon: "arrow.up.forward") {
                    onOpenSettings(.connectors)
                }
            } else if let home = NotchConnectorLinks.home(for: instance) {
                QuickActionButton(title: "Open \(NotchConnectorLinks.appName(for: instance))",
                                  icon: "arrow.up.forward") { onOpenLink(home) }
            }
            Spacer(minLength: Theme.Space.sm)
            QuickActionButton(title: "Unpin", icon: "pin.slash") { model.unpin(connector: id) }
        }
    }

    /// One column: a quiet label over up to three rows, or a single honest line when
    /// there's nothing in it.
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
                NotchQuietLine(emptyLine)
            } else {
                rows()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tab bar

/// Today · Notes │ one tab per pinned connection │ + … gear.
///
/// The selected tab is underlined in ember; a pinned connection carries its count
/// (unread mail, events still ahead) so the bar answers "anything new?" before you
/// click. The "+" opens the Connectors page, where pinning happens, and is only drawn
/// while there is room for another pin and something left to pin.
private struct NotchQuickActionsTabBar: View {
    let model: NotchQuickActionsModel
    let onAddPin: () -> Void

    var body: some View {
        let current = model.currentTab
        let pinned = model.pinnedConnectors
        HStack(spacing: 2) {
            NotchTabButton(title: "Today", isSelected: current == .today) { model.select(.today) }
            NotchTabButton(title: "Notes", isSelected: current == .notes) { model.select(.notes) }
            if !pinned.isEmpty {
                Rectangle()
                    .fill(Theme.Notch.hairline)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 6)
                    .accessibilityHidden(true)
            }
            ForEach(pinned) { instance in
                NotchTabButton(
                    title: instance.displayLabel,
                    icon: instance.kind.icon,
                    badge: model.feed.badge(for: instance.id),
                    isSelected: current == .connector(instance.id)
                ) { model.select(.connector(instance.id)) }
            }
            if model.canPinMore {
                Button(action: onAddPin) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                .iconButton(size: 22, tooltip: "Pin a connector to the notch")
                .accessibilityLabel("Pin a connector to the notch")
            }
            Spacer(minLength: Theme.Space.sm)
            Button { model.select(.settings) } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(current == .settings ? Theme.Notch.text : Theme.Notch.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(current == .settings ? Theme.Notch.controlFillPressed : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Quick settings")
            .accessibilityLabel("Quick settings")
            .accessibilityAddTraits(current == .settings ? .isSelected : [])
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Notch.hairline).frame(height: 1)
        }
    }
}

/// One tab: a label, an optional glyph and count, and an ember rule under it when
/// selected. Hand-tuned rather than the button ladder — a tab is not a button with
/// chrome, and an outlined pill per tab read as a row of actions.
private struct NotchTabButton: View {
    let title: String
    var icon: String?
    var badge: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(Typography.sans(12.5, .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 96, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if let badge {
                    Text(badge > 9 ? "9+" : "\(badge)")
                        .font(Typography.sans(10, .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Ember.on)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Theme.Notch.accent))
                }
            }
            .foregroundStyle(isSelected ? Theme.Notch.text : Theme.Notch.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(Theme.Notch.accent).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A long connection name is cut at `maxWidth`; the tooltip says it whole.
        .nativeTooltip(title)
        .pointerCursor()
        .accessibilityLabel(badge.map { "\(title), \($0) new" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Connector page

/// A pinned connection's page: its rows, or one honest line saying why there are
/// none. **Never an empty list** — "nothing new" and "we lost access to your mail"
/// look identical as blank space and mean opposite things.
private struct NotchConnectorPage: View {
    let instance: ConnectorInstance
    let content: NotchConnectorFeed.Content?
    let isLoading: Bool
    let onOpenLink: (URL) -> Void
    let onJoin: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !instance.isEnabled {
                NotchQuietLine("Paused. Turn it on in Connectors.")
            } else if let error = instance.lastError, !NotchConnectorFeed.shouldRead(instance) {
                NotchQuietLine(error.message, tone: Theme.Notch.danger)
            } else {
                switch content {
                case .items(let items)?:
                    if items.isEmpty {
                        NotchQuietLine("Nothing new.")
                    } else {
                        ForEach(items) { item in
                            NotchConnectorItemRow(item: item, onOpenLink: onOpenLink)
                        }
                    }
                case .events(let events)?:
                    if events.isEmpty {
                        NotchQuietLine("Nothing else today.")
                    } else {
                        let now = Date()
                        ForEach(events) { event in
                            NotchDayTimelineRow(
                                row: NowTimelineRow(
                                    id: event.id,
                                    payload: .event(event),
                                    at: event.isAllDay ? Calendar.current.startOfDay(for: now) : event.start,
                                    isPast: false),
                                now: now,
                                onJoin: onJoin)
                        }
                    }
                case nil:
                    if let error = instance.lastError {
                        NotchQuietLine(error.message, tone: Theme.Notch.danger)
                    } else {
                        NotchQuietLine(isLoading ? "Reading \(instance.displayLabel)\u{2026}" : "Nothing read yet.")
                    }
                }
            }
        }
    }
}

/// One mail, message or task. Unread carries the ember dot; the row opens the item
/// itself when the provider gave a link, and is plain text when it didn't.
private struct NotchConnectorItemRow: View {
    let item: ConnectorItem
    let onOpenLink: (URL) -> Void

    private var link: URL? {
        item.url.flatMap(URL.init(string:)).flatMap { NotchConnectorLinks.isOpenable($0) ? $0 : nil }
    }

    var body: some View {
        // Plain text when there is nothing to open: a disabled button would grey
        // the row out, and a Slack message without a link is not a lesser row.
        if let link {
            Button { onOpenLink(link) } label: { content }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(spoken)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    private var spoken: String {
        "\(item.isUnread ? "Unread, " : "")\(item.title), \(trailing)"
    }

    private var content: some View {
            HStack(spacing: 8) {
                Circle()
                    .fill(item.isUnread ? Theme.Notch.accent : Theme.Notch.textTertiary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .frame(width: 12)
                Text(item.title)
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(trailing)
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            .frame(height: 21)
            .contentShape(Rectangle())
    }

    /// Who or where it came from, then when — "Priya Shah · 9:58".
    private var trailing: String {
        let when = item.timestamp.map { NotchConnectorLinks.age($0) } ?? ""
        return [Self.sender(item.detail), when].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// "Priya Shah <priya@x.com>" → "Priya Shah". A From header is mostly address.
    static func sender(_ detail: String) -> String {
        guard let open = detail.firstIndex(of: "<"), open > detail.startIndex else { return detail }
        let name = detail[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "\"")))
        return name.isEmpty ? detail : name
    }
}

// MARK: - Settings page

/// The switches worth flipping without opening a window: each one takes effect at
/// once, persists, and costs nothing to turn on. **Smart cleanup is deliberately not
/// here** — turning it on starts a 300 MB download whose progress only the Settings
/// window shows. Sound and the idle notch are not here either: they don't persist
/// across launches yet, and a switch that silently reverts is worse than none.
private struct NotchSettingsPage: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Grid(horizontalSpacing: Theme.Space.lg, verticalSpacing: 5) {
                GridRow {
                    NotchSwitchRow(title: "Pause media while listening", isOn: $state.pauseMediaWhileListening)
                    NotchSwitchRow(title: "Read answers aloud", isOn: $state.speakAnswersEnabled)
                }
                GridRow {
                    NotchSwitchRow(title: "Remove filler words", isOn: $state.removeFillerWordsEnabled)
                    NotchSwitchRow(title: "Learn from corrections", isOn: $state.learnCorrectionsEnabled)
                }
            }
            HStack(spacing: 8) {
                Text("Push to talk")
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.textSecondary)
                Text(state.hotkey.displayName)
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Notch.hairline))
                Text("hold to talk \u{00B7} double-tap to keep listening")
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
                    .lineLimit(1)
            }
            .frame(height: 22)
        }
    }
}

/// A label and a compact switch on the ink surface. `ThemeToggle` is drawn for the
/// paper ground (a pale knob on a sunken well) and is 44pt wide; on the bezel it
/// read as a light slab, so the band gets its own at row height.
private struct NotchSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Theme.Signal.base : Theme.Notch.controlFillPressed)
                        .frame(width: 28, height: 16)
                    Circle()
                        .fill(isOn ? Theme.Signal.on : Theme.Notch.textSecondary)
                        .frame(width: 12, height: 12)
                        .padding(2)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.toggle), value: isOn)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

/// The one line a page shows when it has nothing to list.
private struct NotchQuietLine: View {
    let text: String
    var tone: Color = Theme.Notch.textSecondary

    init(_ text: String, tone: Color = Theme.Notch.textSecondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(Typography.notchBody)
            .foregroundStyle(tone)
            .lineLimit(1)
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
    /// The Notes tab has the width to say how old a note is; the Today column
    /// doesn't.
    var showsAge = false
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
                    if showsAge {
                        Text(NotchConnectorLinks.age(note.updatedAt))
                            .font(Typography.notchCaption)
                            .foregroundStyle(Theme.Notch.textTertiary)
                    }
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
