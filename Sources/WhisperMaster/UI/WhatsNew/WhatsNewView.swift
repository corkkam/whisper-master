import AVKit
import SwiftUI

/// What one release brought, as the window's whole contents: a headline, an
/// optional demo video streamed from R2, the highlights, and one way out.
///
/// **The video is a bonus, never the point.** `videoURL` is absent for most
/// notes, the stream can fail, and `ImageRenderer` can't draw AVKit at all — so
/// the pane collapses in each of those cases and the highlights carry the window
/// on their own. Nothing is bundled: the demo is published to the same public
/// bucket as the manifest, between app releases.
struct WhatsNewView: View {
    let release: WhatsNewRelease
    /// The window's own close. Defaults to a no-op because the view is built
    /// once *before* there is a window to close (`WhatsNewWindow.init`).
    var onDismiss: () -> Void = {}

    var body: some View {
        ZStack {
            WarmBackground()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        header
                        if let videoURL = release.videoURL {
                            WhatsNewVideoPane(videoURL: videoURL, posterURL: release.posterURL)
                        }
                        highlights
                    }
                    .padding(Theme.Space.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text("What's new")
                    .monoLabel()
                    .foregroundStyle(Theme.accent)
                Text(subtitle)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(release.headline)
                .font(Typography.largeTitle)
                .tracked(Typography.largeTitleTracking)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Version, plus the publish date when the manifest carried a readable one.
    private var subtitle: String {
        guard let publishedAt = release.publishedAt else { return "Version \(release.version)" }
        return "Version \(release.version) · " + publishedAt.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// A note with no highlights is still worth showing — the headline and the
    /// demo are the news — so the card simply isn't drawn.
    @ViewBuilder
    private var highlights: some View {
        if !release.highlights.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(release.highlights) { highlight in
                    WhatsNewHighlightRow(highlight: highlight)
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button("Got it", action: onDismiss)
                .primaryButton()
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.bottom, Theme.Space.xl)
    }
}

// MARK: - One highlight

private struct WhatsNewHighlightRow: View {
    let highlight: WhatsNewHighlight

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background { Circle().fill(Theme.accentSoft) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(highlight.title)
                    .font(Typography.headline)
                    .tracked(Typography.headlineTracking)
                    .foregroundStyle(Theme.textPrimary)
                if !highlight.body.isEmpty {
                    Text(highlight.body)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The symbol name comes from a remote file, so a typo or a glyph this OS
    /// version doesn't have would draw an empty box next to the text. Anything
    /// AppKit can't resolve falls back to the manifest's default.
    private var symbol: String {
        NSImage(systemSymbolName: highlight.systemImage, accessibilityDescription: nil) != nil
            ? highlight.systemImage
            : WhatsNewHighlight.defaultSymbol
    }
}

// MARK: - The demo video

/// The streamed demo, with the poster held up while the asset resolves.
///
/// Playability is settled *before* a player exists (`AVAsset.load(.isPlayable)`),
/// so an unreachable or unreadable video collapses the pane instead of leaving a
/// black rectangle with a dead play button in the middle of the window.
private struct WhatsNewVideoPane: View {
    let videoURL: URL
    let posterURL: URL?

    @Environment(\.isSnapshot) private var isSnapshot
    @State private var player: AVPlayer?
    @State private var isUnplayable = false

    var body: some View {
        if isUnplayable {
            // Nothing at all, not an empty frame — the highlights close the gap.
            EmptyView()
        } else {
            pane
        }
    }

    private var pane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surfaceGlass2)
            placeholder
            // `VideoPlayer` is NSView-backed, so it renders as the "unsupported"
            // placeholder in a snapshot — the poster stands in there.
            if let player, !isSnapshot {
                VideoPlayer(player: player)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .accessibilityLabel("Demo video")
        .task(id: videoURL) { await load() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if player == nil {
            if let posterURL {
                AsyncImage(url: posterURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ProgressView().controlSize(.small)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func load() async {
        // A snapshot render never draws the player, so it never reaches out.
        guard !isSnapshot, player == nil else { return }
        let asset = AVURLAsset(url: videoURL)
        do {
            guard try await asset.load(.isPlayable) else {
                isUnplayable = true
                return
            }
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        } catch {
            // Offline, a 404, a stream this Mac can't decode — all the same
            // answer: show the note without it.
            Log.app.notice("what's-new video unavailable: \(error.localizedDescription, privacy: .public)")
            isUnplayable = true
        }
    }
}
