import SwiftUI

/// A note as a sticky on the canvas: tinted paper, the title, the body, and — for a
/// note made by voice — what was actually said and a way to hear it.
///
/// **Why a sticky rather than another list row.** Notes arrive by voice, in a hurry,
/// and they are re-read by *scanning*. A uniform list makes every note the same
/// weight and the same shape, so finding one means reading all of them; a canvas of
/// tinted cards gives each note a stable colour and position, which is what makes it
/// findable at a glance. The tint is stored on the note (`colorIndex`), so a note
/// looks the same every time the window opens.
///
/// Two house rules this deliberately keeps rather than breaking for the metaphor:
/// **nothing is rotated** (§6 — the system doesn't do playful transforms, and a
/// rotated card makes its text measurably harder to read), and the tints are
/// desaturated paper rather than highlighter yellow, because ember and signal are
/// spoken for and five loud squares would shout down the rest of the window.
struct StickyNoteCard: View {
    let note: Note
    let player: NoteAudioPlayer
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onTogglePin: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showsTranscript = false
    @State private var isHovering = false

    private var fill: Color { Theme.Sticky.fill(note.colorIndex) }
    private var edge: Color { Theme.Sticky.stroke(note.colorIndex) }
    private var isPlaying: Bool { player.isPlaying(note.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            bodyText
            Spacer(minLength: 0)
            if note.hasAudio || note.distinctTranscript != nil { voiceRow }
            if showsTranscript, let spoken = note.distinctTranscript { transcriptBlock(spoken) }
            footer
        }
        .padding(14)
        .frame(minHeight: 172, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(note.isPinned ? Theme.accent.opacity(0.55) : edge,
                              lineWidth: note.isPinned ? 1.5 : 1)
        }
        .shadow(color: Theme.shadowRaised.color,
                radius: Theme.shadowRaised.radius,
                x: Theme.shadowRaised.x,
                y: Theme.shadowRaised.y)
        // The house hover: 2px up on the house curve, never a scale (§6).
        .offset(y: isHovering ? Theme.StateLayer.lift : 0)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick), value: isHovering)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.quick), value: showsTranscript)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.isPinned
            ? "Pinned note: \(note.displayTitle)"
            : "Note: \(note.displayTitle)")
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(note.displayTitle)
                .font(Typography.headline)
                .tracking(Typography.headlineTracking)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // Pin is the card's primary affordance, so it's always visible rather
            // than hover-revealed — a pinned note has to be able to say so even
            // when the pointer is elsewhere, since the pin is what puts it on the
            // notch.
            Button(action: onTogglePin) {
                Image(systemName: note.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(note.isPinned ? Theme.accent : Theme.textTertiary)
            }
            .iconButton(size: 24,
                        tooltip: note.isPinned ? "Unpin from the notch" : "Pin to the notch")
            .accessibilityLabel(note.isPinned
                ? "Unpin “\(note.displayTitle)”"
                : "Pin “\(note.displayTitle)” to the notch")
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        let trimmed = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Text(trimmed)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The voice row: play the recording, and reveal what was heard.
    ///
    /// These sit together because they answer the same question — "is this really
    /// what I said?" — and a spoken note is the only kind that can be wrong in that
    /// particular way.
    private var voiceRow: some View {
        HStack(spacing: 6) {
            if note.hasAudio {
                Button { player.toggle(note) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(Self.duration(note.audio?.durationMs ?? 0))
                            .font(Typography.sans(11.5, .semibold))
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(isPlaying ? Theme.accentOn : Theme.accent)
                .background {
                    Capsule(style: .continuous)
                        .fill(isPlaying ? Theme.accentFill : Theme.accent.opacity(0.10))
                }
                .pointerCursor()
                .nativeTooltip(isPlaying ? "Stop" : "Play the recording")
                .accessibilityLabel(isPlaying
                    ? "Stop playing this note"
                    : "Play the recording of this note")
                // A synced note names a file this Mac doesn't have — the row still
                // says a recording exists, but the button can't pretend to play it.
                .disabled(isSnapshot || NoteAudioStore.playableURL(for: note) == nil)
            }

            if note.distinctTranscript != nil {
                Button { showsTranscript.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 9, weight: .semibold))
                        Text(showsTranscript ? "Hide what I heard" : "What I heard")
                            .font(Typography.sans(11.5, .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .pointerCursor()
                .accessibilityLabel(showsTranscript
                    ? "Hide the transcription"
                    : "Show the transcription of what was said")
            }
            Spacer(minLength: 0)
        }
    }

    /// The verbatim capture, set apart from the body so it reads as a quotation of
    /// the user rather than as more note content.
    private func transcriptBlock(_ spoken: String) -> some View {
        Text(spoken)
            .font(Typography.sans(12))
            .italic()
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                // A quote rule rather than quote marks — it survives a line wrap.
                Rectangle().fill(edge).frame(width: 2)
            }
            .accessibilityLabel("Transcription: \(spoken)")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(Self.stamp.string(from: note.updatedAt))
                .font(Typography.sans(10.5, .medium))
                .foregroundStyle(Theme.textFaint)
            Spacer(minLength: 4)
            // Edit and delete are hover-revealed: they repeat on every card, and a
            // canvas with two permanent buttons per sticky reads as a toolbar grid.
            // Kept in the accessibility tree regardless — a hover-gated control that
            // VoiceOver can't reach is unreachable, not tidy.
            if isHovering || isSnapshot {
                IconButton("pencil", label: "Edit note", action: onEdit)
                IconButton("trash", label: "Delete note", role: .destructive, action: onDelete)
            }
        }
    }

    // MARK: - Formatting

    /// `m:ss` — a note's recording is seconds-to-minutes long, so an hours field
    /// would be dead width on every card.
    static func duration(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}
