import SwiftUI

/// The notch-anchored dictation surface.
///
/// A single black `NotchShape` wraps the physical notch — extending past it on
/// the left and right and hanging below in a thicker band that holds the
/// `DictationStatusView`. When there's something to show it extrudes downward
/// out of the notch; otherwise it retracts back up and disappears.
struct DictationPillContent: View {
    let state: AppState
    var geometry: NotchGeometry = .none
    var layout: NotchSurfaceLayout = NotchSurfaceLayout()
    /// Tap action for the command-confirmation and due-reminder banners — opens
    /// Settings → Notes & Reminders, so a spoken reminder's default time is one
    /// click from editable and a reminder that just fired is one click from done.
    var onOpenNotes: () -> Void = {}
    /// Puts the transcript that couldn't be pasted on the clipboard — the Copy
    /// button on the undelivered hint. Injected so the view stays AppKit-free;
    /// the owner reads the current (possibly polished) text itself.
    var onCopyUndelivered: () -> Void = {}
    /// Ticks the due reminder off — or puts it back, if it's already ticked. The
    /// owner holds the pre-tick snapshot needed to undo, so the view just asks.
    var onToggleDueReminder: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A failed session gets its own taller band to fit the reason line.
    private var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    /// A reminder that has come due — the app's own scheduled alert, which lands
    /// here rather than in Notification Centre. Outranks every hint below it: the
    /// user set it for a moment, and this band is the whole of its delivery.
    /// (`AppState.canShowDueReminderBanner` already yields it to the approval card
    /// and the undelivered hint, and pauses its clock while it does.)
    private var showDueReminder: Bool { !showApproval && !showAgentAsk && !showAgentGlance && !showAgentWorking && !showAgentReply && state.shouldShowDueReminderBanner }

    /// The "note saved / reminder set" confirmation after a spoken command routed
    /// into Notes & Reminders — highest priority, since the paste was suppressed
    /// and this is the user's only feedback that the words went somewhere.
    private var showCommandConfirmation: Bool { !showApproval && !showAgentAsk && !showAgentGlance && !showAgentWorking && !showAgentReply && !showDueReminder && state.shouldShowCommandConfirmation }

    /// The "what's my day" answer — the immediate result of a connector query the
    /// user just asked for. Just under the command confirmation.
    private var showDaySummary: Bool { !showApproval && !showAgentAsk && !showAgentGlance && !showAgentWorking && !showAgentReply && !showDueReminder && !showCommandConfirmation && state.shouldShowDaySummary }

    /// The "nowhere to paste" hint — the immediate consequence of a dictation
    /// that had no target field.
    /// A write awaiting consent outranks every other banner. Burying a consent card
    /// under a day summary would either lose the write to its timeout or, worse, train
    /// the user to dismiss cards they never read.
    private var showApproval: Bool { state.approvals.pending != nil }

    /// A coding agent holding a turn open on a question. Directly below the connector
    /// approval and above everything else, because it is the same kind of thing: a
    /// caller suspended behind a card. It yields to the connector card because that
    /// one denies itself on a timeout, so it is the one that must not wait.
    private var showAgentAsk: Bool { state.shouldShowAgentAsk }

    /// The surface the user opened with a tap of the agent key: the session list, or
    /// one session's tail once they went in.
    private var showAgentGlance: Bool { !showAgentAsk && state.shouldShowAgentGlance }

    /// A revealed session mid-turn: the slim row, not the panel. See
    /// `AppState.shouldShowAgentWorking` for why a running turn must not hold a
    /// panel-height band open.
    private var showAgentWorking: Bool { !showAgentAsk && state.shouldShowAgentWorking }

    /// The finished turn's answer, as one banner line.
    private var showAgentReply: Bool { !showAgentAsk && state.shouldShowAgentReply }

    /// The agent sessions shown as context under the question. Resolved here as well
    /// as in the panel because the band's thickness depends on whether there are any.
    private var otherAgentSessions: [AgentSession] {
        NotchAgentPanel.otherSessions(
            in: state.agents.sessions, askingRepo: state.agents.askingSession?.repo ?? "")
    }

    /// The width the expanded reply's text actually renders at: the wide surface
    /// minus its own padding. The height is measured at this same number — measuring
    /// at an assumed width while rendering at another is what produced the skinny
    /// over-wrapped tower.
    private var expandedReplyTextWidth: CGFloat {
        layout.expandedReplySurfaceWidth(for: geometry)
            - NotchAgentReplyExpanded.Metrics.horizontalPadding * 2
    }

    /// Read once per render rather than held: the elapsed labels in the context row
    /// only need to be right each time the band repaints, and a stored clock here
    /// would be a second thing to keep ticking.
    private var now: Date { Date() }

    private var showUndelivered: Bool { !showApproval && !showAgentAsk && !showAgentGlance && !showAgentWorking && !showAgentReply && !showCommandConfirmation && !showDaySummary && state.shouldShowUndeliveredBanner }

    /// The "learned a word" confirmation — just under the undelivered hint.
    private var showLearned: Bool { !showApproval && !showAgentAsk && !showAgentGlance && !showAgentWorking && !showAgentReply && !showDueReminder && !showCommandConfirmation && !showDaySummary && !showUndelivered && state.shouldShowLearnedBanner }

    /// The one-shot "smart cleanup is ready" confirmation — just under the
    /// learned hint. (Model download *progress* never appears here.)
    private var showCleanupReady: Bool { !showApproval && !showAgentAsk && !showAgentGlance && !showAgentWorking && !showAgentReply && !showDueReminder && !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && state.shouldShowCleanupReadyBanner }

    /// The Bluetooth-mic hint takes precedence over the dictation indicator and
    /// uses a taller band to fit its text + button.
    private var showBanner: Bool { !showApproval && !showAgentAsk && !showAgentGlance && !showAgentWorking && !showAgentReply && !showDueReminder && !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && !showCleanupReady && state.shouldShowBluetoothBanner }

    /// A gentle reminder — lower priority than the hints above, shown only when
    /// idle (`AppState.shouldShowReminder` already gates that).
    private var showReminder: Bool { !showApproval && !showAgentAsk && !showAgentGlance && !showAgentWorking && !showAgentReply && !showDueReminder && !showCommandConfirmation && !showDaySummary && !showUndelivered && !showLearned && !showCleanupReady && !showBanner && state.shouldShowReminder }

    private var bandThickness: CGFloat {
        if showApproval { return layout.bannerThickness }
        if showAgentAsk, let ask = state.agents.ask {
            return NotchAgentPanel.thickness(
                for: ask, otherSessions: otherAgentSessions.count,
                banner: layout.bannerThickness)
        }
        if showAgentReply {
            guard state.agents.replyExpanded, let reply = state.agents.lastReply else {
                return layout.bannerThickness
            }
            return NotchAgentReplyExpanded.thickness(
                for: AgentReplyDocument.parse(state.agents.lastReplyRaw ?? reply),
                prompt: state.agents.log.lastUserPrompt,
                toolCount: state.agents.log.currentTurnTools.count,
                width: expandedReplyTextWidth)
        }
        if showAgentGlance {
            return NotchAgentGlance.listThickness(sessionCount: state.agents.sessions.count)
        }
        if showDueReminder { return layout.dueReminderThickness }
        if showCommandConfirmation { return layout.commandConfirmationThickness }
        if showDaySummary { return layout.daySummaryThickness }
        if showUndelivered { return layout.undeliveredThickness }
        if showLearned { return layout.learnedThickness }
        if showCleanupReady { return layout.cleanupReadyThickness }
        if showBanner { return layout.bannerThickness }
        if showReminder { return layout.reminderThickness }
        if isFailed { return layout.failedThickness }
        // The polished line is the one band that breathes: it takes a row per
        // wrapped line, up to the three-line window.
        let model = transcriptModel
        if !model.isEmpty { return layout.transcriptThickness(lines: model.visibleLineCount) }
        return layout.bottomThickness // lone orb + delivered beat both slim
    }

    /// Whether the surface draws **in** the menu-bar row instead of in a band
    /// hanging below the notch.
    ///
    /// This is the status line's resting form: while there is nothing to read, the
    /// state word and the orb sit in the menu bar itself, on either side of the
    /// camera housing — at the notch's own height, which is what makes it read as
    /// part of the menu bar rather than an overlay laid on top of one. Since the
    /// live transcript is never shown (see `transcriptModel`), this is now the form
    /// a whole dictation is spent in; the notch only opens downward for something a
    /// band is needed for: a banner, a failure reason, a download percentage, the
    /// polished line.
    ///
    /// The wings are wider than half the notch body (190pt vs ~104pt either side),
    /// so the leading label and trailing orb land outside the camera housing
    /// without any special-casing.
    private var isNotchRow: Bool {
        // An agent mid-turn takes the same resting form a dictation does: the
        // caption in one wing, the orb in the other, at menu-bar height. Rendering
        // it as a dropped band put a slab of empty black under the bezel with a
        // caption lost in it — nothing else in the app treats "working" that way.
        if showAgentWorking { return true }
        guard bandIsDictation || isDeliveredBadge else { return false }
        return transcriptModel.isEmpty
    }

    private var rowThickness: CGFloat { layout.rowThickness(for: geometry) }

    private var expandedHeight: CGFloat {
        isNotchRow ? rowThickness : geometry.notchHeight + bandThickness
    }

    /// Whether one of the banners is what the band is carrying. `band` below picks
    /// them in this same order; this is the single "not the dictation indicator"
    /// test the width, thickness and glow all read from.
    private var bandIsBanner: Bool {
        showApproval || showAgentAsk || showAgentGlance || showAgentWorking || showAgentReply || showDueReminder || showCommandConfirmation || showDaySummary || showUndelivered
            || showLearned || showCleanupReady || showBanner || showReminder
    }

    /// Whether the band is the *transcript-bearing* dictation indicator. Narrower
    /// than "not a banner": a failure and a model download both render through
    /// `DictationStatusView` too, but each has its own width and thickness.
    private var bandIsDictation: Bool {
        !bandIsBanner && !isFailed && state.download == nil
    }

    /// What the dictation band is doing, as one named state — the value that picks
    /// the orb figure, the state word, **and** the hue the surface is lit in, so
    /// those three can't disagree.
    ///
    /// `.idle` whenever a banner is what's showing: the banners carry their own
    /// meaning and chrome, and lighting the band signal-green behind a Bluetooth
    /// warning would say two different things at once.
    /// Gated on `bandIsBanner`, not `bandIsDictation`: a failure and a download are
    /// dictation states that deserve their light (danger, and a quiet signal), even
    /// though neither carries a transcript.
    private var activity: NotchActivity {
        // The agent bands are the two banners that earn light: a finished reply is
        // a delivery (centre signal bloom, like the checkmark's), and a running
        // turn is machine work (trailing signal, like transcribing). Every other
        // banner stays matte and carries its own colour.
        // The agent bands are matte, like every other banner. The delivered glow
        // was tried behind the reply card and read as a murky gradient smudge
        // under a full card of text — the design system's own warning about a
        // saturated hue at low alpha over pure black. Its character comes from
        // the rails and the type, not haze.
        return bandIsBanner ? .idle : NotchActivity.resolve(from: state)
    }

    /// The words the band is carrying, resolved here rather than in the row so the
    /// band's thickness and the row's line count come from the same wrap — no
    /// measurement round-trip, no one-frame lag between the two.
    ///
    /// **The live transcript is deliberately not shown.** The band reports the
    /// *state* of a dictation, never the words as they stream: reading your own
    /// speech back off the bezel pulls your eyes away from whatever you're
    /// dictating into, and the words are already landing there. So this is empty
    /// for the whole recording → finalizing → polishing stretch — which is what
    /// keeps the surface in its slim menu-bar row form (`isNotchRow`) throughout.
    ///
    /// The one exception is the finished **polished** beat: the rewrite already
    /// happened, so holding the new line for a moment is the only way the
    /// substitution isn't invisible.
    ///
    /// It is resolved at the **expanded** width unconditionally, which looks
    /// circular (the width depends on whether there's a transcript) but isn't:
    /// an empty model means the compact surface, and a non-empty one means the
    /// expanded surface, so the expanded width is the right width whenever the
    /// answer is used at all.
    private var transcriptModel: NotchTranscriptModel {
        guard bandIsDictation,
              state.shouldShowPolishedBeat,
              let polished = state.polishedText
        else { return NotchTranscriptModel() }
        return .resolve(
            confirmed: polished,
            partial: "",
            width: NotchTranscriptRow.textWidth(
                surfaceWidth: layout.surfaceWidth(for: geometry, .wide))
        )
    }

    /// Which of the three widths the current band wants. Dictation is the bar,
    /// sized to the state word it carries; the delivered checkmark stays a bare
    /// badge; every hint is written against the banner width.
    ///
    /// The approval card is the one *banner* that takes the bar: it carries three
    /// buttons alongside its two lines, and at banner width the words and the
    /// answers were competing for the same ~200pt.
    private var surfaceKind: NotchSurfaceWidth {
        // The agent panel carries three buttons beside an unbounded command, or a
        // column of model-authored options. Both need the bar, for the same reason
        // the connector approval card does.
        // The reply — collapsed or expanded — takes the bar: "show me the whole
        // thing" at banner width was a skinny tower of over-wrapped text.
        if showApproval || showAgentAsk || showAgentGlance || showAgentWorking
            || showAgentReply { return .wide }
        guard bandIsDictation else { return .banner }
        return isDeliveredBadge ? .glyph : .wide
    }

    /// The delivered checkmark on its own — the one dictation state with nothing
    /// to read and nothing running, so it doesn't earn the bar. Mirrors
    /// `DictationStatusView`'s branch order, which puts the working states first.
    private var isDeliveredBadge: Bool {
        !state.shouldShowLiveTranscript
            && !state.shouldShowPolishedBeat
            && state.preparingEngine == nil
            && state.shouldShowDeliveredBeat
    }

    /// Width of the black surface. The panel itself is always sized for the widest
    /// state, so the surface is framed inside it and centered on the notch.
    ///
    /// The bar's width follows its state word, because the assistant's captions
    /// carry a user-chosen connector name and the leading label lives in the wing:
    /// a caption longer than `wideSideExtension` would otherwise run under the
    /// camera housing rather than widening the band.
    private var surfaceWidth: CGFloat {
        // The expanded reply is the "big notch": it takes the widest surface the
        // panel was sized for, the same cap the assistant's longest captions reach.
        if showAgentReply, state.agents.replyExpanded {
            return layout.expandedReplySurfaceWidth(for: geometry)
        }
        return layout.surfaceWidth(for: geometry, surfaceKind, stateLabel: stateLabel)
    }

    /// The state word the bar is carrying, or "" for every surface that isn't the
    /// bar. Resolved here because it decides the width as well as the content.
    private var stateLabel: String {
        // The working row's caption carries a file name or a repo name, so like the
        // assistant's connector captions it has to grow the wing rather than
        // truncate against the base width.
        if showAgentWorking, let session = state.agents.openSession {
            return NotchAgentWorkingRow.caption(for: session, now: now)
        }
        guard surfaceKind == .wide, transcriptModel.isEmpty else { return "" }
        return activity.label(
            holdToTalk: state.holdToTalkEnabled && !state.handsFreeActive,
            commandCapture: state.commandCaptureArmed || state.commandAgentRunning,
            agentActivity: state.agentActivity,
            agentTarget: state.agentCaptureArmed
                ? (state.agents.promptTarget?.repo ?? "the agent") : nil)
    }

    /// Ceiling on the leading label in the row form, so a caption past the wing cap
    /// truncates at the housing's edge instead of disappearing behind it.
    private var rowLabelMaxWidth: CGFloat {
        layout.rowLabelMaxWidth(
            for: geometry, wing: layout.wideWing(forStateLabel: stateLabel))
    }

    /// Whether the surface should be dropped down and visible.
    private var isExpanded: Bool {
        // Hints, the delivered beat, and the polish that runs on after a paste
        // all show even when idle. The approval card leads that list because it is
        // the one band with a *caller suspended behind it*: it was only ever on
        // screen because `isPolishing` happened to be holding the band open for the
        // agent loop around it, so anything that raised a card outside that window
        // would have left a write waiting on a question nobody was shown, until it
        // timed out and denied itself.
        if showApproval
            || showAgentAsk
            || showAgentGlance
            || showAgentWorking
            || showAgentReply
            || showDueReminder || showCommandConfirmation || showDaySummary || showUndelivered || showLearned || showCleanupReady || showBanner || showReminder
            || state.shouldShowDeliveredBeat || state.shouldShowLiveTranscript
            || state.shouldShowPolishedBeat { return true }
        guard hasContent else { return false }
        if state.phase == .idle && state.hidePillWhenIdle { return false }
        return true
    }

    /// Whether any state is worth surfacing at all.
    private var hasContent: Bool {
        if state.download != nil || state.preparingEngine != nil { return true }
        if state.shouldShowDeliveredBeat { return true }
        if state.shouldShowLiveTranscript || state.shouldShowPolishedBeat { return true }
        switch state.phase {
        case .recording, .preparingModels, .stopping, .failed: return true
        case .idle: return false
        }
    }

    var body: some View {
        let shape = NotchShape(
            topConcaveRadius: layout.topConcaveRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        )

        Group {
            if isNotchRow {
                // Drawn *in* the menu-bar row: no dead-zone, because the content
                // lives in the wings either side of the camera housing rather than
                // below it.
                band
                    .frame(maxWidth: .infinity)
                    .frame(height: rowThickness)
            } else {
                VStack(spacing: 0) {
                    // Camera dead-zone — nothing renders behind the physical notch.
                    // Non-hittable so clicks above the band fall through to the
                    // menu bar.
                    Color.clear
                        .frame(height: geometry.notchHeight)
                        .allowsHitTesting(false)

                    band
                        .frame(maxWidth: .infinity)
                        .frame(height: bandThickness)
                }
            }
        }
        .frame(width: surfaceWidth, height: isExpanded ? expandedHeight : 0, alignment: .top)
        // Pitch-black fill molded to the physical notch, lit from inside by the
        // current state: ember while it's hearing you, signal while the machine
        // works, danger on a failure. The glow is *inside* the shape (drawn over
        // the fill, under the content) so the clip keeps it molded to the notch —
        // outside it, the light would spill past the band's rounded corners.
        .background {
            shape.fill(Theme.Notch.surface)
                .overlay { NotchGlow(activity: activity) }
                .clipShape(shape)
        }
        .clipShape(shape)
        .opacity(isExpanded ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Only the interactive banners take clicks (the Bluetooth "use built-in"
        // button, the tappable command confirmation, and the undelivered hint's
        // Copy button); the dictation indicator stays click-through (the panel
        // toggles ignoresMouseEvents to match).
        .allowsHitTesting(showApproval || showAgentAsk || showAgentGlance || showAgentReply || showAgentWorking || showBanner || showCommandConfirmation || showUndelivered || showDueReminder)
        // Appear *instantly* (no animation when expanding), animate only the
        // retract. A spring on the way in read as "the notch appears late" even
        // though the state flips synchronously on key-press. Banners (below) keep
        // the softer spring since they slide in inside an already-open notch.
        .animation(isExpanded ? nil : Theme.Motion.respecting(reduceMotion, Theme.Motion.retract), value: isExpanded)
        // The surface widens when the first words land and narrows when they go —
        // animated so it reads as the notch making room, not as a size jump.
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: surfaceWidth)
        // …and it deepens a row at a time as the transcript wraps onto new lines.
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick), value: bandThickness)
        // The notch opening out of the menu-bar row (and closing back into it) is
        // the surface's biggest move, so it gets the settle curve.
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: isNotchRow)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showUndelivered)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showLearned)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showCleanupReady)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showBanner)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showReminder)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showCommandConfirmation)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showDaySummary)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick), value: state.isSpeakingAnswer)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showApproval)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showAgentAsk)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showAgentGlance)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showAgentWorking)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showAgentReply)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: showDueReminder)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: state.shouldShowDeliveredBeat)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.appear), value: state.shouldShowPolishedBeat)
    }

    @ViewBuilder
    private var band: some View {
        if showApproval, let approval = state.approvals.pending {
            NotchApprovalBanner(approval: approval) { outcome in
                state.approvals.resolve(outcome)
            }
        } else if showAgentAsk, let ask = state.agents.ask {
            NotchAgentPanel(
                ask: ask,
                sessions: state.agents.sessions,
                askingRepo: state.agents.askingSession?.repo ?? "",
                mode: state.agents.askingSession?.mode ?? .ask,
                now: now,
                onResolve: { allow, always in
                    state.agents.resolve(ask, allow: allow, always: always)
                },
                onAnswer: { question, selected in
                    guard case .choice(let choice) = ask else { return }
                    state.agents.answer(choice, question: question, selected: selected)
                },
                onSelectMode: { state.agents.setMode($0) })
        } else if showAgentWorking, let session = state.agents.openSession {
            NotchAgentWorkingRow(
                session: session, now: now,
                orbSize: layout.rowOrbDiameter(for: geometry),
                verticalInset: layout.rowVerticalPadding,
                labelMaxWidth: rowLabelMaxWidth,
                onStop: { state.agents.interrupt() })
        } else if showAgentReply, let reply = state.agents.lastReply {
            // Click for the whole thing; click again for the one-liner. The full
            // reply is stored raw, so the expanded band re-presents it from source
            // rather than expanding the truncated line.
            Group {
                if state.agents.replyExpanded {
                    NotchAgentReplyExpanded(
                        document: AgentReplyDocument.parse(state.agents.lastReplyRaw ?? reply),
                        prompt: state.agents.log.lastUserPrompt,
                        repo: state.agents.openSession?.repo ?? "",
                        duration: state.agents.lastTurnDuration,
                        editedPaths: state.agents.changeSet.editedPaths,
                        tools: state.agents.log.currentTurnTools,
                        textWidth: expandedReplyTextWidth,
                        kunaiURL: state.agents.openSessionURL)
                } else {
                    NotchAgentReplyBanner(
                        reply: reply,
                        repo: state.agents.openSession?.repo ?? "",
                        duration: state.agents.lastTurnDuration)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { state.agents.toggleReplyExpansion() }
        } else if showAgentGlance {
            NotchAgentGlance(
                sessions: state.agents.sessions,
                selectedID: state.agents.promptTarget?.id,
                now: now,
                onOpen: { state.agents.open(sessionID: $0.id) })
        } else if showDueReminder, let reminder = state.dueReminder {
            NotchDueReminderBanner(
                reminder: reminder,
                isCompleted: state.dueReminderCompleted,
                onToggle: onToggleDueReminder,
                onOpen: onOpenNotes)
        } else if showCommandConfirmation, let message = state.commandConfirmation {
            NotchCommandConfirmationBanner(
                message: message,
                detail: state.commandConfirmationDetail,
                icon: state.commandConfirmationIcon)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenNotes)
        } else if showDaySummary, let summary = state.activeDaySummary {
            NotchDaySummaryBanner(summary: summary, isSpeaking: state.isSpeakingAnswer)
        } else if showUndelivered {
            NotchUndeliveredBanner(text: state.undeliveredText ?? "", onCopy: onCopyUndelivered)
        } else if showLearned, let term = state.learnedTerm {
            NotchLearnedBanner(term: term)
        } else if showCleanupReady {
            NotchCleanupReadyBanner()
        } else if showBanner {
            NotchBluetoothBanner(state: state)
        } else if showReminder, let line = state.activeReminder {
            NotchReminderBanner(text: line)
        } else {
            DictationStatusView(
                state: state,
                transcript: transcriptModel,
                activity: activity,
                rowOrbSize: isNotchRow ? layout.rowOrbDiameter(for: geometry) : nil,
                rowVerticalInset: isNotchRow ? layout.rowVerticalPadding : nil,
                rowLabelMaxWidth: isNotchRow ? rowLabelMaxWidth : nil
            )
        }
    }
}
