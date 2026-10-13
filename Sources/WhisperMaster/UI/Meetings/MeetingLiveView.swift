import AppKit
import SwiftUI

/// The floating window beside a call: what was said on the left, running notes
/// and your own notes on the right, and the one Stop button.
///
/// A real window, not the notch: the notch never carries live transcript (see
/// `UI/CLAUDE.md`), and typing your own notes needs a key window, which a
/// non-activating bezel panel cannot be. Closing it does not stop the meeting;
/// the tray's "Stop meeting notes" and this window's Stop both do.
@MainActor
final class MeetingLiveWindow {
    private let controller: MeetingController
    private var panel: NSPanel?

    init(controller: MeetingController) {
        self.controller = controller
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.title = "Meeting notes"
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 520, height: 320)
            panel.contentView = NSHostingView(rootView: MeetingLiveView(controller: controller))
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 740, y: frame.maxY - 500))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

struct MeetingLiveView: View {
    let controller: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if let session = controller.session {
                HStack(spacing: 0) {
                    MeetingTranscriptColumn(session: session)
                    Divider().overlay(Theme.line)
                    MeetingNotesColumn(session: session)
                        .frame(width: 260)
                }
            } else {
                placeholder
            }
        }
        .padding(.top, 28)  // under the transparent title bar
        .background(Theme.canvas)
        .foregroundStyle(Theme.textPrimary)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            if let session = controller.session {
                Circle().fill(Theme.danger).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.call.calendarTitle ?? session.call.name)
                        .font(Typography.headline)
                        .lineLimit(1)
                    TimelineView(.periodic(from: session.startedAt, by: 30)) { context in
                        Text(Self.status(session: session, now: context.date))
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                Button("Stop") { controller.stopNotes() }
                    .primaryButton()
            } else {
                Text("Meeting notes").font(Typography.headline)
                Spacer()
                if controller.isWritingNotes {
                    ProgressView().controlSize(.small)
                    Text("Writing notes").font(Typography.caption)
                } else {
                    Button("Start notes") { controller.takeNotes() }
                        .secondaryButton()
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    private var placeholder: some View {
        VStack(spacing: Theme.Space.sm) {
            if let error = controller.lastError {
                Text(error).font(Typography.body).foregroundStyle(Theme.danger)
            } else if controller.isWritingNotes {
                Text("Writing notes. They will be in Notes when done.").font(Typography.body)
            } else if let title = controller.readyNoteTitle {
                Text("Saved to Notes: \(title)").font(Typography.body)
            } else {
                Text("No meeting is being recorded.").font(Typography.body)
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func status(session: MeetingSession, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(session.startedAt) / 60))
        var parts = [minutes < 1 ? "Recording, under 1 min" : "Recording, \(minutes) min"]
        if !session.capturesCallAudio { parts.append("mic only") }
        if session.micLost { parts.append("mic lost") }
        return parts.joined(separator: " · ")
    }
}

/// `ImageRenderer` draws nothing inside a `ScrollView`, so the PNG renderer gets
/// the same content laid out flat.
private struct SnapshotSafeScroll<Content: View>: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @ViewBuilder let content: Content

    var body: some View {
        if isSnapshot {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content }
        }
    }
}

private struct MeetingTranscriptColumn: View {
    let session: MeetingSession

    var body: some View {
        ScrollViewReader { proxy in
            SnapshotSafeScroll {
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    if session.transcript.isEmpty {
                        Text("The transcript appears here about 15 seconds after people start talking.")
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(session.transcript.cleanedSegments) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(segment.speaker.label) · \(MeetingTranscript.timestamp(segment.atMs))")
                                .font(Typography.label)
                                .foregroundStyle(segment.speaker == .me ? Theme.accent : Theme.accent2)
                            Text(segment.text)
                                .font(Typography.body)
                                .textSelection(.enabled)
                        }
                        .id(segment.id)
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.transcript.segments.count) {
                if let last = session.transcript.cleanedSegments.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

private struct MeetingNotesColumn: View {
    @Bindable var session: MeetingSession
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Live notes").font(Typography.label).foregroundStyle(Theme.textTertiary)
            SnapshotSafeScroll {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if session.liveNotes.isEmpty {
                        Text(CleanupModel.General.isInstalled
                             ? "Notes are added every 3 minutes."
                             : "Install the assistant model in Settings to get notes.")
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(Array(session.liveNotes.enumerated()), id: \.offset) { _, block in
                        Text(block).font(Typography.subheadline).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            Text("My notes").font(Typography.label).foregroundStyle(Theme.textTertiary)
            Group {
                // `ImageRenderer` cannot draw `TextEditor`; the renderer gets a
                // static stand-in with the same frame.
                if isSnapshot {
                    Text(session.ownNotes)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: $session.ownNotes)
                        .scrollContentBackground(.hidden)
                }
            }
                .font(Typography.subheadline)
                .padding(Theme.Space.xs)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.surface))
                .frame(height: 120)
        }
        .padding(Theme.Space.lg)
    }
}
