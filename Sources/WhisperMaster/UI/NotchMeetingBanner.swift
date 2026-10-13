import SwiftUI

/// "Meeting detected · Slack huddle  [Take notes] [x]" — offered once when a call
/// app takes the mic. Interactive, so it is in `DictationPillContent`'s
/// `allowsHitTesting` and the AppDelegate's `setInteractive`. It retracts after
/// `MeetingController.promptDuration` on its own; the tray still offers
/// "Take meeting notes" after that. The context menu holds "Never for <app>",
/// which is too rare an answer to spend band width on.
struct NotchMeetingPromptBanner: View {
    let call: DetectedCall
    let controller: MeetingController

    var body: some View {
        NotchBannerRow(
            icon: "person.2.wave.2.fill",
            title: "Meeting detected",
            subtitle: call.calendarTitle.map { "\(call.name) · \($0)" } ?? call.name
        ) {
            Spacer(minLength: Theme.Space.sm)

            Button("Take notes") { controller.takeNotes() }
                .buttonStyle(.plain)
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.Notch.text.opacity(0.12)))
                .pointerCursor()

            Button("Not now", systemImage: "xmark") { controller.dismissPrompt() }
                .labelStyle(.iconOnly)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Notch.textTertiary)
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .pointerCursor()
        }
        .contextMenu {
            if !call.bundleFamily.isEmpty {
                Button("Never for \(call.name)") { controller.ignorePromptApp() }
            }
        }
    }
}

/// "Meeting notes saved · <title>" — tap to open Notes.
struct NotchMeetingReadyBanner: View {
    let title: String

    var body: some View {
        NotchBannerRow(icon: "note.text", title: "Meeting notes saved", subtitle: title)
    }
}
