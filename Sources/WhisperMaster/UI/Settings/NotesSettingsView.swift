import AppKit
import SwiftUI

/// Which half of Notes & Reminders is on screen.
///
/// `overview` is the landing state and shows **both** — notes on the left,
/// reminders on the right — because the two are one mental space ("what have I
/// written down, what's coming up") and making the user pick one before they can
/// see anything is a tab too early. The other two are the focused views, reachable
/// from these tabs or straight from the sidebar's sub-rows.
enum NotesTab: String, CaseIterable, Identifiable {
    case overview
    case notes
    case reminders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .notes: return "note.text"
        case .reminders: return "bell.badge"
        }
    }
}

/// The "Notes & Reminders" tab: freeform notes on a sticky canvas plus time-based
/// reminders that alert as a notch banner or a looping alarm. Per-account, synced
/// across Macs (see `NotesStore` / `NotesSyncClient`). Alert style + sound have
/// global defaults here and a per-reminder override in the editor.
///
/// **Notes are a canvas, reminders are a list**, and that asymmetry is the point:
/// a note is re-read by scanning (so it gets a stable colour and a card — see
/// `StickyNoteCard`), a reminder is read by *time* (so it gets one ordered column,
/// soonest first). Pinning a note floats it to the front of the canvas and puts it
/// on the notch band, which is the only way a note reaches the bezel.
struct NotesSettingsView: View {
    @Bindable var state: AppState
    /// Owned by `SettingsView` so the sidebar's Notes/Reminders sub-rows and these
    /// tabs are the same selection — two controls disagreeing about which half you
    /// are looking at is worse than either alone.
    @Binding var tab: NotesTab
    @Environment(\.isSnapshot) private var isSnapshot

    /// Non-nil drafts drive the editor sheets. A fresh item = "add"; an existing
    /// one = "edit" (same id, so `upsert` replaces it).
    @State private var reminderDraft: ReminderItem?
    @State private var noteDraft: Note?
    /// The chord explanation, which lives in a popover off the header chip rather
    /// than in a permanent card above the content.
    @State private var showsAssistantHelp = false
    /// Whether the archive is expanded. Collapsed on arrival — finished work is
    /// reference material, and the page's job is what's left. Ticking something off
    /// opens it, so the row is seen to *land* somewhere rather than just vanish.
    @State private var showsCompleted = false
    @State private var confirmingClearCompleted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: NotesStore { state.notesStore }

    /// How many archived reminders the section renders before it stops. The archive
    /// is a safety net, not a log — past this the count in the header is the honest
    /// summary and "Clear" is the answer.
    private static let archiveDisplayLimit = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            toolbarRow
            switch tab {
            case .overview:
                overviewSplit
            case .notes:
                notesCanvas
            case .reminders:
                // Back to the reading measure. The page is given the canvas's wide
                // measure (`SettingsView.contentMaxWidth`) because the *notes* grid
                // needs it, but a reminder is one row: at 1180 its title sat a
                // thousand points from its own done/edit/delete buttons, so the eye
                // had to cross the whole window to connect them. Only the grid earns
                // that width.
                VStack(alignment: .leading, spacing: 22) {
                    remindersSection
                    completedSection
                    alertDefaultsSection
                }
                .frame(maxWidth: 820, alignment: .leading)
            }
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

    // MARK: - Reminders

    /// What's left to do. Ticking a row moves it out of here and into the archive
    /// below, so this list only ever answers one question.
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Reminders")
                Spacer()
                SecondaryButton(title: "Add reminder", icon: "plus") { newReminder() }
                    .disabled(isSnapshot)
            }
            remindersList(store.activeReminders)
        }
    }

    /// The archive — everything ticked off, most recent first, collapsed by default.
    ///
    /// It exists because a tick used to leave the row exactly where it was, struck
    /// through and sorted by due date among the live ones: done work went on
    /// competing for attention with work that wasn't, and the only surface that
    /// offered an *un*-tick was the notch. So completion now moves the row somewhere
    /// with a name, and the undo lives there rather than nowhere.
    ///
    /// The whole section is absent until something has actually been completed — an
    /// empty "Completed (0)" header on a fresh account is a promise of clutter.
    @ViewBuilder
    private var completedSection: some View {
        let done = store.completedReminders
        if !done.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                completedHeader(count: done.count)
                if showsCompleted {
                    SettingsCard {
                        ForEach(Array(done.prefix(Self.archiveDisplayLimit).enumerated()),
                                id: \.element.id) { index, reminder in
                            if index > 0 { RowDivider() }
                            reminderRow(reminder)
                        }
                        if done.count > Self.archiveDisplayLimit {
                            RowDivider()
                            Text("\(done.count - Self.archiveDisplayLimit) older not shown.")
                                .font(Typography.subheadline)
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 13)
                        }
                    }
                }
            }
        }
    }

    /// The archive's own header: a disclosure that carries its count (so a collapsed
    /// section still tells you how much is behind it) and, once open, the way to
    /// empty it.
    private func completedHeader(count: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick)) {
                    showsCompleted.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                    SectionLabel("Completed")
                    Text("\(count)")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(showsCompleted
                ? "Hide \(count) completed reminders"
                : "Show \(count) completed reminders")

            Spacer(minLength: 6)

            if showsCompleted, !isSnapshot {
                Button("Clear") { confirmingClearCompleted = true }
                    .textButton()
                    .accessibilityLabel("Clear all completed reminders")
            }
        }
        .confirmationDialog(
            "Clear \(count) completed reminder\(count == 1 ? "" : "s")?",
            isPresented: $confirmingClearCompleted
        ) {
            Button("Clear", role: .destructive) {
                withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.settle)) {
                    _ = store.clearCompletedReminders()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're removed for good. Anything still to do is untouched.")
        }
    }

    /// The reminders column — one card, soonest first. Shared by the Reminders tab
    /// (everything) and the Overview column (the next few), so the two can't drift
    /// into two different row designs.
    @ViewBuilder
    private func remindersList(_ reminders: [ReminderItem], compact: Bool = false) -> some View {
        if reminders.isEmpty {
            // Two different silences. Nothing ever set is a prompt to set one;
            // nothing *left* is a result, and it should say where the work went
            // rather than read as if the list had been wiped.
            if store.completedReminders.isEmpty {
                emptyCard("No reminders yet",
                          "Add one and Whisper Master will nudge you at the right time.")
            } else {
                emptyCard("All caught up",
                          "Nothing left to do. What you've ticked off is under Completed.")
            }
        } else {
            SettingsCard {
                ForEach(Array(reminders.enumerated()), id: \.element.id) { index, reminder in
                    if index > 0 { RowDivider() }
                    reminderRow(reminder, compact: compact)
                }
            }
        }
    }

    /// One reminder, in either list.
    ///
    /// **The checkbox leads the row**, where the eye starts and next to the thing it
    /// completes — it used to be one of three identical grey glyphs in a trailing
    /// cluster, which on an 820pt row put "done" a full window-width from the title
    /// it applied to, and made the single most-used action look like the least. It's
    /// the same affordance the notch banner and the quick-actions panel already use,
    /// and like those it **ticks both ways**: the archive row's filled box is the
    /// undo, so a mis-click is fixed where it happened.
    ///
    /// `compact` is the Overview column, which is a fixed 330pt: the alert/sound
    /// chips and the delete button are dropped there rather than letting them squeeze
    /// the title to nothing. Everything stays reachable one tab over.
    private func reminderRow(_ reminder: ReminderItem, compact: Bool = false) -> some View {
        let status = statusLine(reminder)
        return HStack(alignment: .top, spacing: compact ? 9 : 12) {
            completionBox(reminder)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(reminder.displayTitle)
                        .font(Typography.headline).tracking(Typography.headlineTracking)
                        .foregroundStyle(reminder.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(reminder.isCompleted, color: Theme.textTertiary)
                        .lineLimit(compact ? 1 : nil)
                    if reminder.isRepeating {
                        Image(systemName: "repeat")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel(reminder.repeatRule.displayName)
                    }
                }
                Text(status.text)
                    .font(Typography.subheadline)
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
                // A finished reminder isn't going to alert again, so its alert style
                // and sound are answers to a question nobody is asking any more.
                if !compact, !reminder.isCompleted {
                    HStack(spacing: 6) {
                        Chip(reminder.alertStyle.displayName)
                        Chip(ReminderSound.label(for: reminder.soundName))
                    }
                }
            }
            Spacer(minLength: compact ? 4 : 12)
            HStack(spacing: compact ? 2 : 8) {
                // Editing a done reminder means resurrecting it, which the checkbox
                // already does more plainly — so the archive row offers delete alone.
                if !reminder.isCompleted {
                    IconButton("pencil", label: "Edit reminder") { reminderDraft = reminder }
                }
                if !compact {
                    IconButton("trash", label: "Delete reminder", role: .destructive) {
                        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick)) {
                            store.deleteReminder(reminder.id)
                        }
                    }
                }
            }
        }
        .padding(.vertical, compact ? 11 : 15)
    }

    /// The leading checkbox. Filled + signal when done (a settled machine state, §1),
    /// hollow otherwise.
    private func completionBox(_ reminder: ReminderItem) -> some View {
        Button { toggleCompletion(reminder) } label: {
            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(reminder.isCompleted ? Theme.success : Theme.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isSnapshot)
        .accessibilityLabel(completionLabel(reminder))
        .nativeTooltip(completionLabel(reminder))
    }

    /// Says what the tap will actually do — including the one case where "done"
    /// doesn't mean done: a repeating reminder rolls to its next occurrence instead
    /// of completing, so promising an archive here would be a lie the user only
    /// discovers by tapping.
    private func completionLabel(_ reminder: ReminderItem) -> String {
        if reminder.isCompleted { return "Mark \(reminder.displayTitle) as not done" }
        if reminder.isRepeating,
           let next = reminder.repeatRule.nextDue(after: max(reminder.dueDate, Date())) {
            return "Mark this one done — next \(Self.dueFormatter.string(from: next))"
        }
        return "Mark \(reminder.displayTitle) done"
    }

    /// Tick, or un-tick.
    ///
    /// Ticking a one-off **opens the archive** so the row is watched out of one list
    /// and into another: a row that simply disappears reads as a deletion, and the
    /// undo has to be somewhere the user just saw. A repeating reminder leaves the
    /// archive alone — it never lands there, it just re-dates in place.
    ///
    /// Un-ticking goes through `restoreReminder(_:)` with the row's own snapshot
    /// rather than an id, for the same reason the notch does: completion isn't a flag
    /// flip, and only the caller holds the occurrence that was rolled away.
    private func toggleCompletion(_ reminder: ReminderItem) {
        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.settle)) {
            if reminder.isCompleted {
                store.restoreReminder(reminder)
            } else {
                if !reminder.isRepeating { showsCompleted = true }
                store.completeReminder(reminder.id)
            }
        }
    }

    /// The row's second line: when it's due, when it was done, or how late it is.
    ///
    /// Overdue is the one state worth colour. It was previously indistinguishable
    /// from any other date — the list said "Nov 3 at 9:00 AM" in the same grey
    /// whether that was tomorrow or a fortnight ago.
    private func statusLine(_ reminder: ReminderItem) -> (text: String, tint: Color) {
        if reminder.isCompleted {
            let when = Self.relativeFormatter.localizedString(for: reminder.archivedAt, relativeTo: Date())
            return ("Done \(when)", Theme.textTertiary)
        }
        let due = Self.dueFormatter.string(from: reminder.dueDate)
        if reminder.isRepeating { return ("Next · \(due)", Theme.textSecondary) }
        if reminder.dueDate < Date() { return ("Overdue · \(due)", Theme.danger) }
        return (due, Theme.textSecondary)
    }

    // MARK: - Tabs

    /// The page's one toolbar row: the section switch on the left, the shortcut hint
    /// on the right.
    ///
    /// Both used to take a full-width block of their own — the tabs on one row and a
    /// three-line "Say it instead of typing it" card with its own section label under
    /// them, which together pushed the first actual note about 200pt down the page on
    /// every single visit. A switch and a hint are both *chrome*; they share one row.
    private var toolbarRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.lg) {
            tabBar
            Spacer(minLength: Theme.Space.sm)
            assistantHint
        }
    }

    /// The Overview / Notes / Reminders switch.
    ///
    /// **Styled to match the sidebar's selection, deliberately.** The first version
    /// filled the selected segment with `accent2Fill` on the reasoning that selection
    /// is the machine talking (§1) — but the sidebar 250pt to the left had already
    /// settled how selection looks in this app: a soft ember wash, ember ink, a
    /// hairline. A saturated teal slab beside it meant two selection languages in one
    /// window, and made navigation chrome the loudest thing on a page whose job is to
    /// show notes. So the selected segment is a raised `Theme.selection` pill (the
    /// token that exists for exactly this) with ember ink, over a sunken track.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(NotesTab.allCases) { candidate in
                let isSelected = candidate == tab
                Button { tab = candidate } label: {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(candidate.title)
                            .font(Typography.sans(13, isSelected ? .semibold : .medium))
                        if let count = badgeCount(for: candidate) {
                            Text("\(count)")
                                .font(Typography.sans(10.5, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? Theme.accent.opacity(0.7) : Theme.textFaint)
                        }
                    }
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textSecondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Theme.selection)
                                .shadow(color: Theme.shadowRaised.color,
                                        radius: 6, x: 0, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        // A *sunken* track, not glass: the selected pill is near-white, so the well
        // behind it has to be darker than the page or the selection has nothing to
        // lift off (the same reason the window ground sits a step below white).
        .background(Capsule(style: .continuous).fill(Theme.surfaceSunken.opacity(0.55)))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.lineSoft, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes and reminders sections")
    }

    // MARK: - The assistant hint

    /// The shortcut, top-right, as a chip — with the explanation one click away.
    ///
    /// This replaced a full-width card holding three lines of prose. The tension:
    /// the chord is the *primary* way notes get created here, so it has to stay
    /// discoverable — but a paragraph nobody re-reads doesn't earn permanent space
    /// above the content. So the **keycap stays visible forever** (that's the part
    /// that teaches), and the prose moves into a popover for whoever actually wants
    /// it. Not a tooltip: this is real explanatory copy with examples, and a tooltip
    /// can't be read at leisure or reached by keyboard.
    private var assistantHint: some View {
        Button { showsAssistantHelp.toggle() } label: {
            HStack(spacing: 7) {
                // No leading glyph: `compactName` already opens with the Globe
                // character for the fn key ("🌐 FN + ^ CTRL"), so an `Image(systemName:
                // "globe")` in front of it rendered the same key twice.
                Text(ModifierChord.command.compactName)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Text("to talk to the assistant")
                    .font(Typography.sans(12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Image(systemName: "info.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Theme.surfaceGlass))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isSnapshot)
        .accessibilityLabel(
            "Talk to the assistant with \(ModifierChord.command.displayName). Show details.")
        .popover(isPresented: $showsAssistantHelp, arrowEdge: .bottom) {
            assistantHelpCard
        }
    }

    private var assistantHelpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Say it instead of typing it")
                .font(Typography.headline).tracking(Typography.headlineTracking)
                .foregroundStyle(Theme.textPrimary)
            Text("Hold \(ModifierChord.command.compactName) and speak — “take a note that the wifi password is…”, “remind me to call mom tomorrow”, “what's on my calendar?”.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("Let go and it's handled instead of typed: notes and reminders land here, questions are answered in the notch. Reminders with no stated time get a default you can tap to change.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Theme.Space.lg)
        .frame(width: 340)
    }

    /// Counts on the focused tabs only. Overview holds both, so a number there would
    /// be the sum of two unrelated things.
    private func badgeCount(for candidate: NotesTab) -> Int? {
        switch candidate {
        case .overview: return nil
        case .notes:
            let count = store.visibleNotes.count
            return count > 0 ? count : nil
        case .reminders:
            let count = store.activeReminders.count
            return count > 0 ? count : nil
        }
    }

    // MARK: - Overview (both halves)

    /// Notes beside reminders. The notes side takes the flexible width because cards
    /// need it; reminders are a fixed column, since a time and a title don't get more
    /// readable with more room.
    private var overviewSplit: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    "Notes",
                    action: "Add note",
                    onAdd: { noteDraft = Note() },
                    onSeeAll: { tab = .notes })
                stickyGrid(store.visibleNotes, minimum: 210)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    "Reminders",
                    action: "Add reminder",
                    onAdd: { newReminder() },
                    onSeeAll: { tab = .reminders })
                // Active only. The Overview column is five slots of "what's coming";
                // spending one of them on something already done is the clutter this
                // whole split exists to remove, and the archive is one click away
                // under "See all".
                remindersList(store.activeReminders.prefix(5).map { $0 }, compact: true)
            }
            .frame(width: 330, alignment: .topLeading)
        }
    }

    // MARK: - Notes canvas

    private var notesCanvas: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                SectionLabel("Notes")
                Spacer()
                SecondaryButton(title: "Add note", icon: "plus") { noteDraft = Note() }
                    .disabled(isSnapshot)
            }

            if store.visibleNotes.isEmpty {
                emptyCard("No notes yet",
                          "Hold \(ModifierChord.command.compactName) and say “take a note that…”, or add one here. Pin the ones you want on the notch.")
            } else {
                // Pinned notes get their own labelled band above the rest. Pinning is
                // a claim about importance, and mixing pinned cards into one long
                // grid — even sorted first — loses that claim as soon as the grid
                // wraps to a second row.
                if !store.pinnedNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        pinnedLabel
                        stickyGrid(store.pinnedNotes, minimum: 240)
                    }
                }
                if !store.unpinnedNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        if !store.pinnedNotes.isEmpty {
                            Text("EVERYTHING ELSE")
                                .font(Typography.label).tracking(1.4)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        stickyGrid(store.unpinnedNotes, minimum: 240)
                    }
                }
            }
        }
    }

    private var pinnedLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("PINNED — ON THE NOTCH")
                .font(Typography.label).tracking(1.4)
                .foregroundStyle(Theme.accent)
        }
    }

    /// The canvas itself. `adaptive` rather than a fixed column count so the grid
    /// reflows with the window instead of holding a layout that only fits one size.
    private func stickyGrid(_ notes: [Note], minimum: CGFloat) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimum, maximum: 340), spacing: 14)],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(notes) { note in
                StickyNoteCard(
                    note: note,
                    player: state.noteAudioPlayer,
                    onEdit: { noteDraft = note },
                    onDelete: { store.deleteNote(note.id) },
                    onTogglePin: { store.setPinned(note.id, !note.isPinned) })
            }
        }
    }

    /// A section head with an add button and a "see all" that switches tabs — used on
    /// Overview, where each half is a preview of a fuller view.
    private func sectionHeader(
        _ title: String,
        action: String,
        onAdd: @escaping () -> Void,
        onSeeAll: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            SectionLabel(title)
            Spacer(minLength: 6)
            Button(action: onSeeAll) {
                HStack(spacing: 3) {
                    Text("See all").font(Typography.caption)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("See all \(title.lowercased())")

            IconButton("plus", label: action, action: onAdd)
                .disabled(isSnapshot)
        }
    }

    private func newReminder() {
        reminderDraft = ReminderItem(
            dueDate: Date().addingTimeInterval(3_600),
            alertStyle: state.reminderDefaultAlertStyle,
            soundName: state.reminderDefaultSound)
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

    /// "2 hours ago" for the archive. A finished reminder is read for recency, and an
    /// absolute timestamp makes the reader do that subtraction themselves.
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
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
