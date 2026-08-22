import SwiftUI

/// The ambient slot: the one thing that is relevant right now, in the notch's
/// leading wing.
///
/// **It shares the row rather than taking it.** The trailing wing keeps the orb
/// and whatever the app itself is doing, so a meeting three minutes away is still
/// readable while a dictation or a coding agent is running — which is the whole
/// reason this surface exists. The previous arrangement gave the leading wing to
/// the state word, and every machine state pushed the day off the bezel entirely.
///
/// **It is inert apart from one control.** The band sits over the menu bar, so a
/// surface that took clicks across its whole width for the ten minutes before a
/// meeting would be swallowing menu-bar clicks that whole time. Everything here is
/// explicitly non-hittable except the Join button and the reminder checkbox, and
/// the host marks its own background non-hittable to match — so a click anywhere
/// else falls through to the menu bar exactly as it does today.
struct NotchNowRow: View {
    let item: NowItem
    let now: Date
    /// Ceiling on the whole row, so a long event title truncates at the wing's
    /// edge instead of running under the camera housing.
    var maxWidth: CGFloat?
    /// Tick the reminder off. `nil` for the event rungs.
    var onToggle: (() -> Void)?
    /// Open the call. `nil` when the invitation carried no recognised link.
    var onJoin: ((URL) -> Void)?
    /// Whether this row draws the Join pill itself.
    ///
    /// False in the ambient-*only* form, where the host puts it at the trailing
    /// edge instead: with nothing else on the bar that wing is empty, and a band
    /// with all its content bunched against one end reads as a slab rather than as
    /// the notch opening out. While a dictation or an agent is running the wing is
    /// spoken for, so the pill stays inline here.
    var showsJoin: Bool = true

    var body: some View {
        HStack(spacing: 7) {
            marker
            Text(item.title)
                .font(Typography.notchLabel)
                .foregroundStyle(Theme.Notch.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsHitTesting(false)
            Text(NowPhrase.moment(for: item, now: now))
                .font(Typography.notchBody)
                .foregroundStyle(momentTint)
                .lineLimit(1)
                .layoutPriority(1)
                .allowsHitTesting(false)
            if showsJoin, let url = item.joinURL, let onJoin, Self.isJoinable(item) {
                NotchJoinButton(title: item.title) { onJoin(url) }
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.spoken(item, now: now))
    }

    /// A checkbox for a reminder, a dot for an event. The checkbox is the same
    /// affordance the due-reminder banner and the quick-actions panel use, and it
    /// is here for the same reason: "done" needs no keyboard, and an overdue
    /// reminder on the bezel is usually one tap from finished.
    @ViewBuilder
    private var marker: some View {
        if item.reminderID != nil, let onToggle {
            Button(action: onToggle) {
                Image(systemName: "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Notch.accent)
            }
            .iconButton(size: 18, tooltip: "Mark done")
            .accessibilityLabel("Mark “\(item.title)” done")
        } else {
            Circle()
                .fill(markerTint)
                .frame(width: 6, height: 6)
                .allowsHitTesting(false)
        }
    }

    /// Ember for the user's own things, amber for a meeting inside its horizon, a
    /// quiet grey for the hour-ahead look-ahead. The look-ahead is deliberately
    /// colourless: it is not news, it is orientation.
    private var markerTint: Color {
        switch item.kind {
        case .meetingNow, .meetingSoon: return Theme.Notch.warning
        case .reminderOverdue, .reminderSoon: return Theme.Notch.accent
        case .nextEvent: return Theme.Notch.textTertiary
        }
    }

    private var momentTint: Color {
        switch item.kind {
        case .meetingNow, .reminderOverdue: return Theme.Notch.warning
        case .meetingSoon, .reminderSoon: return Theme.Notch.textSecondary
        case .nextEvent: return Theme.Notch.textTertiary
        }
    }

    /// Whether this rung is one you can join. A reminder never is, and neither is
    /// the hour-ahead look-ahead — a Join pill on something an hour away invites a
    /// click into an empty room.
    static func isJoinable(_ item: NowItem) -> Bool {
        item.joinURL != nil && (item.kind == .meetingNow || item.kind == .meetingSoon)
    }

    /// One sentence for VoiceOver, since the row reads as three fragments.
    static func spoken(_ item: NowItem, now: Date) -> String {
        let moment = NowPhrase.moment(for: item, now: now)
        switch item.kind {
        case .meetingNow: return "\(item.title), happening now"
        case .meetingSoon: return "\(item.title), starts \(moment)"
        case .reminderOverdue: return "\(item.title), overdue"
        case .reminderSoon: return "\(item.title), due \(moment)"
        case .nextEvent: return "Next: \(item.title) at \(moment)"
        }
    }

    /// The string the wing is measured against — the row's own text, joined the
    /// way it is laid out, so `NotchSurfaceLayout.wideWing` grows the band to fit
    /// it rather than letting the tail slide under the camera housing.
    ///
    /// The Join button and the marker are charged as a fixed allowance rather than
    /// measured, because both are constant-width and measuring a `Button` means
    /// laying it out.
    static func sizingLabel(_ item: NowItem, now: Date) -> String {
        let base = "\(item.title) \(NowPhrase.moment(for: item, now: now))"
        let hasJoin = isJoinable(item)
        // "MMMM" is the marker's 6pt dot plus its gap; "MMMMMMM" covers the Join
        // pill. Measured in the same face as the label, which is what makes them
        // comparable to the real text at all.
        return base + (hasJoin ? " MMMMMMM" : " MM")
    }
}

/// Everything the leading slot needs, in one value the row-form views pass along.
///
/// A struct rather than five parameters threaded through `NotchTranscriptRow`,
/// `DictationStatusView` and `NotchAgentWorkingRow`: it is either present or it is
/// not, and "present" is exactly the condition those views branch on.
struct NotchAmbientSlot {
    let item: NowItem
    let now: Date
    var maxWidth: CGFloat?
    var onToggle: (() -> Void)?
    var onJoin: ((URL) -> Void)?

    func row(showsJoin: Bool = true) -> NotchNowRow {
        NotchNowRow(
            item: item, now: now, maxWidth: maxWidth,
            onToggle: onToggle, onJoin: onJoin, showsJoin: showsJoin)
    }

    /// The trailing-edge Join pill for the ambient-*only* form, or nil when there
    /// is nothing to join. Built here rather than in the host so the joinable test
    /// lives in one place.
    @ViewBuilder
    var trailingJoin: some View {
        if let url = item.joinURL, let onJoin, NotchNowRow.isJoinable(item) {
            NotchJoinButton(title: item.title) { onJoin(url) }
        }
    }
}

/// The app's own state, demoted to a chip beside the orb.
///
/// While the ambient slot is empty the state word keeps the leading edge, exactly
/// as it always has. When the slot fills, the two would be one run-on sentence
/// across the camera housing — so the state moves next to the orb and takes a
/// chip, which is what says "this belongs to the thing on the right" rather than
/// "this continues the sentence on the left".
struct NotchStateChip: View {
    let label: String
    /// Ember while the app is hearing you, signal for machine work — the same
    /// division `NotchGlow` makes, so the chip and the light agree.
    var isListening: Bool = false

    var body: some View {
        Text(label)
            .font(Typography.sans(11, .semibold))
            .foregroundStyle(isListening ? Theme.Notch.accent : Theme.Notch.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(
                    isListening
                        ? Theme.Notch.accent.opacity(0.14)
                        : Color.white.opacity(0.07))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The Join pill, hand-tuned for the bezel.
///
/// **Not `.outlinedButton()`.** The button ladder only lands on `Theme.Notch`
/// tokens under `.onDarkSurface()`, and the dictation surface deliberately does
/// not apply it — the notch banners' own pills are hand-tuned for the same reason
/// (they are measured against `NotchGeometry`, and a capsule swap changes the
/// band's metrics). Reaching for the ladder here drew the app's light ink on black
/// and the pill was invisible; this is the shape `NotchApprovalBanner` already
/// uses for its three answers.
struct NotchJoinButton: View {
    /// The event's name, for the spoken label only.
    let title: String
    let action: () -> Void

    var body: some View {
        Button("Join", action: action)
            .buttonStyle(.plain)
            .font(Typography.notchCaption)
            .foregroundStyle(Theme.Notch.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.Notch.text.opacity(0.14)))
            .pointerCursor()
            .accessibilityLabel("Join \(title)")
    }
}
