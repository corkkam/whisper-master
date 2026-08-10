import SwiftUI

/// Layout directions for the finished turn, drawn so one can be chosen from a
/// render rather than from a description.
///
/// **These are candidates, not shipping surfaces.** They carry sample content, no
/// measurement, and no state; only the direction that gets picked is built for real
/// and the rest are deleted.
///
/// Round one (receipt / editorial / session log) was one idea — type on black
/// separated by hairlines — in three arrangements. Round two (bento / broadsheet /
/// colour block / window) changed the material but stayed a dashboard. This round
/// goes for elegance instead of information density: a page with real margins, a
/// thread drawn out of the notch itself, and the answer arriving on paper.
enum ReplyLayoutCandidate {

    /// The content every candidate is drawn with, so the comparison is about the
    /// layout rather than about which one got the flattering paragraph.
    enum Sample {
        static let repo = "whisper-master"
        static let elapsed = "3m 12s"
        static let question = "Fix the flaky audio route test, and clear the build first."
        static let lead =
            "Cleared the build, then rewrote the route assertion to wait on the rebuilt "
            + "engine instead of a fixed delay."
        static let code = """
            ✓ AudioRouteTests           42 passed   0 failed
            ✓ TranscriptMergerTests     18 passed   0 failed
            """
        static let tail =
            "The flake was the fixed delay racing the engine rebuild on slower runs, so "
            + "it only showed up under load."
        static let tools: [(time: String, text: String)] = [
            ("00:01", "rm -rf build/"),
            ("00:04", "swift test --filter AudioRoute"),
            ("02:51", "edit  Audio/RouteTests.swift"),
        ]
        static let changed = ["Audio/RouteTests.swift"]
        /// The run reduced to one quiet line — an index, not a list.
        static let runIndex = "rm -rf build/  ·  swift test --filter AudioRoute  ·  edit RouteTests.swift"
    }
}

// MARK: - H. Letter

/// **H — Letter.** No panels, no tiles, no rules between things: a page with real
/// margins. The question hangs in the left margin the way a marginal note does, the
/// answer is set as prose at a generous size with wide leading, and the run is one
/// quiet index line at the foot. The elegance is the restraint — the notch opens and
/// hands you something that reads like a page, not a dashboard.
struct ReplyCandidateLetter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("YOU ASKED")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(Theme.Notch.accent.opacity(0.85))
                    Text(ReplyLayoutCandidate.Sample.question)
                        .font(Typography.heading(15, .semibold, relativeTo: .headline))
                        .tracking(Typography.trackingFor(15))
                        .lineSpacing(4)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Theme.Notch.text.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    Rectangle()
                        .fill(Theme.Notch.hairline)
                        .frame(width: 26, height: 1)
                        .padding(.vertical, 20)

                    Text(ReplyLayoutCandidate.Sample.elapsed)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Notch.textSecondary)
                    Text(ReplyLayoutCandidate.Sample.repo)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Notch.textTertiary)
                        .padding(.top, 3)
                    Text("1 file changed")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Notch.textTertiary)
                        .padding(.top, 3)
                }
                .frame(width: 216, alignment: .trailing)

                VStack(alignment: .leading, spacing: 20) {
                    Text(ReplyLayoutCandidate.Sample.lead)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ReplyLayoutCandidate.Sample.code)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.Notch.success)
                        .padding(.leading, 2)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Theme.Notch.success.opacity(0.5))
                                .frame(width: 1)
                                .offset(x: -16)
                        }
                    Text(ReplyLayoutCandidate.Sample.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typography.sans(16, .regular, relativeTo: .body))
                .lineSpacing(9)
                .foregroundStyle(Theme.Notch.text.opacity(0.9))
                .frame(width: 560, alignment: .leading)

                Spacer(minLength: 0)
            }

            Spacer(minLength: 40)

            HStack(spacing: 0) {
                Text(ReplyLayoutCandidate.Sample.runIndex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 24)
                Text("copy")
                Text("kunai").padding(.leading, 16)
                Text("esc").padding(.leading, 16)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.Notch.textTertiary.opacity(0.75))
            .padding(.top, 22)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Notch.hairline).frame(height: 1)
            }
        }
        .padding(.horizontal, 46)
        .padding(.top, 34)
        .padding(.bottom, 24)
    }
}

// MARK: - I. Thread

/// **I — Thread.** One ember line is drawn *out of the notch itself*, curves down
/// into the left margin, and becomes the spine of the turn: your question at the top
/// of it, each tool call a small ring on it, the answer flowing beside it, and a
/// filled node where it ends. The only candidate that could not belong to any other
/// app — the thing it hangs from is the hardware.
struct ReplyCandidateThread: View {
    /// Where the thread lands after it leaves the notch.
    private let spineX: CGFloat = 74
    private let notchCenterX: CGFloat = 460

    var body: some View {
        ZStack(alignment: .topLeading) {
            ThreadPath(fromX: notchCenterX, toX: spineX, drop: 26, radius: 30)
                .stroke(
                    LinearGradient(
                        colors: [Theme.Notch.accent, Theme.Notch.accent.opacity(0.28)],
                        startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            VStack(alignment: .leading, spacing: 0) {
                node(filled: true, tint: Theme.Notch.accent)
                    .padding(.leading, spineX - 4)
                    .padding(.top, 66)

                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: spineX + 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ReplyLayoutCandidate.Sample.question)
                            .font(Typography.heading(19, .semibold, relativeTo: .title3))
                            .tracking(Typography.trackingFor(19))
                            .lineSpacing(3)
                            .foregroundStyle(Theme.Notch.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 520, alignment: .leading)

                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(
                                Array(ReplyLayoutCandidate.Sample.tools.enumerated()),
                                id: \.offset
                            ) { _, tool in
                                HStack(spacing: 14) {
                                    node(filled: false, tint: Theme.Notch.textTertiary)
                                        .offset(x: -34)
                                        .frame(width: 0)
                                    Text(tool.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.Notch.textTertiary)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(.top, 22)

                        HStack(alignment: .top, spacing: 14) {
                            node(filled: true, tint: Theme.Notch.success)
                                .offset(x: -34)
                                .frame(width: 0)
                            VStack(alignment: .leading, spacing: 16) {
                                Text(ReplyLayoutCandidate.Sample.lead)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(ReplyLayoutCandidate.Sample.code)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineSpacing(4)
                                    .foregroundStyle(Theme.Notch.success)
                                Text(ReplyLayoutCandidate.Sample.tail)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(Typography.sans(14.5, .regular, relativeTo: .body))
                            .lineSpacing(6)
                            .foregroundStyle(Theme.Notch.text.opacity(0.9))
                            .frame(width: 560, alignment: .leading)
                        }
                        .padding(.top, 24)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(ReplyLayoutCandidate.Sample.elapsed)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.Notch.textSecondary)
                        Text(ReplyLayoutCandidate.Sample.repo)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.Notch.textTertiary)
                        Text("copy · kunai · esc")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.Notch.textTertiary.opacity(0.75))
                            .padding(.top, 10)
                    }
                    .padding(.trailing, 40)
                }
                .padding(.top, 14)
            }
        }
        .padding(.bottom, 34)
    }

    private func node(filled: Bool, tint: Color) -> some View {
        Circle()
            .strokeBorder(tint, lineWidth: 1.5)
            .background(Circle().fill(filled ? tint : Theme.Notch.surface))
            .frame(width: 8, height: 8)
    }

    /// The line that leaves the notch: straight down out of the housing, one quarter
    /// turn, then straight down the margin. Drawn as a path so the corner is a true
    /// radius rather than two rectangles meeting.
    private struct ThreadPath: Shape {
        let fromX: CGFloat
        let toX: CGFloat
        let drop: CGFloat
        let radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: fromX, y: 0))
            path.addLine(to: CGPoint(x: fromX, y: drop))
            path.addQuadCurve(
                to: CGPoint(x: fromX - radius, y: drop + radius),
                control: CGPoint(x: fromX, y: drop + radius))
            path.addLine(to: CGPoint(x: toX + radius, y: drop + radius))
            path.addQuadCurve(
                to: CGPoint(x: toX, y: drop + radius * 2),
                control: CGPoint(x: toX, y: drop + radius))
            path.addLine(to: CGPoint(x: toX, y: rect.maxY))
            return path
        }
    }
}

// MARK: - J. Paper

/// **J — Paper.** The swing. This whole app is warm paper and ink — the window, the
/// settings, the notes — and the notch band is the one place that is always black.
/// So the answer *arrives on paper*: your question stays on the bezel in the app's
/// own ink voice, and what the machine wrote is handed to you as a cream card resting
/// on the black. Nothing else in the product looks like this, and it is unmistakably
/// this product.
struct ReplyCandidatePaper: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.Notch.accent)
                    .frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOU ASKED")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(Theme.Notch.textTertiary)
                    Text(ReplyLayoutCandidate.Sample.question)
                        .font(Typography.sans(15, .semibold, relativeTo: .body))
                        .foregroundStyle(Theme.Notch.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                HStack(spacing: 7) {
                    Circle().fill(Theme.Notch.success).frame(width: 5, height: 5)
                    Text("\(ReplyLayoutCandidate.Sample.repo) · \(ReplyLayoutCandidate.Sample.elapsed)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Notch.textTertiary)
                }
            }

            // The card. Warm ground, ink type, the app's own paper brought onto the
            // bezel — with a real shadow, because the whole point is that it is
            // resting on the black rather than cut into it.
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 0) {
                    Text("THE ANSWER")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                    ForEach(
                        Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset
                    ) { index, tool in
                        if index > 0 {
                            Text("·").foregroundStyle(Theme.textFaint).padding(.horizontal, 7)
                        }
                        Text(tool.text.split(separator: " ").first.map(String.init) ?? "")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text("· 1 file changed")
                        .foregroundStyle(Theme.textFaint)
                        .padding(.leading, 7)
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))

                Text(ReplyLayoutCandidate.Sample.lead)
                    .font(Typography.sans(15.5, .regular, relativeTo: .body))
                    .lineSpacing(7)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ReplyLayoutCandidate.Sample.code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.Signal.ink)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10).fill(Theme.paper300.opacity(0.7)))

                Text(ReplyLayoutCandidate.Sample.tail)
                    .font(Typography.sans(15.5, .regular, relativeTo: .body))
                    .lineSpacing(7)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer()
                    paperAction("Copy answer", glyph: "square.on.square")
                    paperAction("Open in kunai", glyph: "arrow.up.forward")
                }
                .padding(.top, 2)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.55), radius: 24, y: 10))

            HStack {
                Spacer()
                Text("click anywhere, or esc, to close")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.7))
                Spacer()
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func paperAction(_ title: String, glyph: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph).font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.paper200))
    }
}
