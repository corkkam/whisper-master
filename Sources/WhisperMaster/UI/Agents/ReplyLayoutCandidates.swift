import SwiftUI

/// Layout directions for the finished turn, drawn so one can be chosen from a
/// render rather than from a description.
///
/// **These are candidates, not shipping surfaces.** They carry sample content, no
/// measurement, and no state; only the direction that gets picked is built for real
/// and the rest are deleted. Round one (receipt / editorial / session log) was
/// rejected wholesale — all three were type on a black band separated by hairlines,
/// which is one idea in three arrangements. This round changes the *material*: a
/// grid of tiles, a printed page, a colour block, and a window.
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
    }

    /// Every tile, well and block on this page uses one radius and one fill, so the
    /// candidates differ by composition rather than by corner rounding.
    enum Tile {
        static let radius: CGFloat = 16
        static let fill = Color.white.opacity(0.045)
        static let raisedFill = Color.white.opacity(0.075)
        static let inset: CGFloat = 18
        static let gap: CGFloat = 12
    }
}

// MARK: - D. Bento

/// **D — Bento.** The turn broken into tiles: the question across the top, the answer
/// in one big pane, and the run, the result and the files each in their own small
/// pane beside it. Nothing is separated by a hairline; every part of the turn is an
/// object you can point at, and the sizes say which matters.
struct ReplyCandidateBento: View {
    var body: some View {
        VStack(spacing: ReplyLayoutCandidate.Tile.gap) {
            tile {
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.Notch.accent)
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 7) {
                        label("You asked")
                        Text(ReplyLayoutCandidate.Sample.question)
                            .font(Typography.sans(16, .semibold, relativeTo: .body))
                            .foregroundStyle(Theme.Notch.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: ReplyLayoutCandidate.Tile.gap) {
                tile {
                    VStack(alignment: .leading, spacing: 13) {
                        label("The answer")
                        Text(ReplyLayoutCandidate.Sample.lead)
                            .font(Typography.sans(14, .regular, relativeTo: .body))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.Notch.text.opacity(0.93))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(ReplyLayoutCandidate.Sample.code)
                            .font(.system(size: 11, design: .monospaced))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.Notch.success)
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.4)))
                        Text(ReplyLayoutCandidate.Sample.tail)
                            .font(Typography.sans(14, .regular, relativeTo: .body))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.Notch.text.opacity(0.93))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: 656)

                VStack(spacing: ReplyLayoutCandidate.Tile.gap) {
                    tile {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Finished in")
                            Text(ReplyLayoutCandidate.Sample.elapsed)
                                .font(Typography.heading(30, .bold, relativeTo: .largeTitle))
                                .tracking(Typography.trackingFor(30))
                                .foregroundStyle(Theme.Notch.success)
                            HStack(spacing: 6) {
                                Circle().fill(Theme.Notch.success).frame(width: 5, height: 5)
                                Text(ReplyLayoutCandidate.Sample.repo)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.Notch.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    tile {
                        VStack(alignment: .leading, spacing: 9) {
                            label("Ran")
                            ForEach(
                                Array(ReplyLayoutCandidate.Sample.tools.enumerated()),
                                id: \.offset
                            ) { _, tool in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.Notch.success)
                                    Text(tool.text)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.Notch.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    tile {
                        VStack(alignment: .leading, spacing: 9) {
                            label("Changed")
                            ForEach(ReplyLayoutCandidate.Sample.changed, id: \.self) { path in
                                Text(path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.Notch.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: ReplyLayoutCandidate.Tile.gap) {
                        pillAction("Copy answer", glyph: "square.on.square")
                        pillAction("kunai", glyph: "arrow.up.forward")
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 320)
            }
            .frame(height: 356)
        }
        .padding(20)
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(ReplyLayoutCandidate.Tile.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ReplyLayoutCandidate.Tile.radius)
                    .fill(ReplyLayoutCandidate.Tile.fill))
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(Theme.Notch.textTertiary)
    }

    private func pillAction(_ title: String, glyph: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph).font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.Notch.text)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(ReplyLayoutCandidate.Tile.raisedFill))
    }
}

// MARK: - E. Broadsheet

/// **E — Broadsheet.** The turn set as a printed page: a dateline, the question as a
/// headline across the measure, then the answer flowing in columns with rules
/// between them. Columns are the point — they keep a long answer *short*, so the
/// band stays a wide strip under the notch instead of a tower down the screen.
struct ReplyCandidateBroadsheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("WHISPER-MASTER")
                Text("·")
                Text("3 TOOL CALLS")
                Text("·")
                Text("1 FILE CHANGED")
                Spacer()
                Text(ReplyLayoutCandidate.Sample.elapsed.uppercased())
            }
            .font(.system(size: 9, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(Theme.Notch.textTertiary)

            Rectangle().fill(Theme.Notch.text.opacity(0.5)).frame(height: 2)
                .padding(.top, 10)

            Text(ReplyLayoutCandidate.Sample.question)
                .font(Typography.heading(30, .bold, relativeTo: .largeTitle))
                .tracking(Typography.trackingFor(30))
                .lineSpacing(2)
                .foregroundStyle(Theme.Notch.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.top, 16)

            Rectangle().fill(Theme.Notch.hairline).frame(height: 1)
                .padding(.top, 18)

            HStack(alignment: .top, spacing: 0) {
                column {
                    Text(ReplyLayoutCandidate.Sample.lead)
                        .font(Typography.sans(13.5, .regular, relativeTo: .body))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.Notch.text.opacity(0.93))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ReplyLayoutCandidate.Sample.tail)
                        .font(Typography.sans(13.5, .regular, relativeTo: .body))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.Notch.text.opacity(0.93))
                        .fixedSize(horizontal: false, vertical: true)
                }
                rule
                column {
                    Text(ReplyLayoutCandidate.Sample.code)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.Notch.success)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Both suites green on the rebuilt engine, so the assertion no "
                        + "longer depends on timing.")
                        .font(Typography.sans(13.5, .regular, relativeTo: .body))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.Notch.text.opacity(0.93))
                        .fixedSize(horizontal: false, vertical: true)
                }
                rule
                column {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("THE RUN")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(Theme.Notch.textTertiary)
                        ForEach(
                            Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset
                        ) { _, tool in
                            HStack(alignment: .top, spacing: 9) {
                                Text(tool.time)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.7))
                                Text(tool.text)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.Notch.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Text("CHANGED")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(Theme.Notch.textTertiary)
                            .padding(.top, 6)
                        ForEach(ReplyLayoutCandidate.Sample.changed, id: \.self) { path in
                            Text(path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.Notch.textSecondary)
                        }
                    }
                }
            }
            .padding(.top, 18)

            Rectangle().fill(Theme.Notch.hairline).frame(height: 1).padding(.top, 18)

            HStack(spacing: 20) {
                Text("COPY ANSWER")
                Text("OPEN IN KUNAI")
                Spacer()
                Text("ESC TO CLOSE")
            }
            .font(.system(size: 9, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.Notch.textTertiary)
            .padding(.top, 12)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(width: 312, alignment: .leading)
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.Notch.hairline)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 21)
    }
}

// MARK: - F. Colour block

/// **F — Colour block.** A full-height ember panel carries your question in reversed
/// display type; the answer lives on the bezel beside it. The one candidate that
/// spends real colour instead of a 3pt tick, so the two voices in the exchange are
/// two *surfaces* rather than two shades of grey.
struct ReplyCandidateColourBlock: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("YOU ASKED")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.Ember.on.opacity(0.55))
                Text(ReplyLayoutCandidate.Sample.question)
                    .font(Typography.heading(24, .bold, relativeTo: .title))
                    .tracking(Typography.trackingFor(24))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.Ember.on)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                Spacer(minLength: 24)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Done in \(ReplyLayoutCandidate.Sample.elapsed)")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Theme.Ember.on.opacity(0.8))
                Text(ReplyLayoutCandidate.Sample.repo)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Ember.on.opacity(0.6))
                    .padding(.top, 5)
            }
            .padding(28)
            .frame(width: 380, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .background(Theme.Ember.base)

            VStack(alignment: .leading, spacing: 14) {
                Text(ReplyLayoutCandidate.Sample.lead)
                    .font(Typography.sans(14.5, .regular, relativeTo: .body))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.Notch.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ReplyLayoutCandidate.Sample.code)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.Notch.success)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                Text(ReplyLayoutCandidate.Sample.tail)
                    .font(Typography.sans(14.5, .regular, relativeTo: .body))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.Notch.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 18)
                HStack(spacing: 0) {
                    ForEach(
                        Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset
                    ) { index, tool in
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.Notch.success)
                            Text(tool.text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.Notch.textSecondary)
                                .lineLimit(1)
                        }
                        if index < ReplyLayoutCandidate.Sample.tools.count - 1 {
                            Rectangle()
                                .fill(Theme.Notch.hairline)
                                .frame(width: 1, height: 12)
                                .padding(.horizontal, 14)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 330)
    }
}

// MARK: - G. Window

/// **G — Window.** The turn as an actual window sitting under the notch: a title bar
/// with dots and a tab, and the run underneath as a terminal session — your line at
/// a prompt, the commands as they ran, the answer as output. The most literal of the
/// four, and the one a developer reads without being taught how.
struct ReplyCandidateWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.white.opacity(0.18), .white.opacity(0.18), Theme.Notch.success],
                        id: \.self) { dot in
                    Circle().fill(dot).frame(width: 9, height: 9)
                }
                Spacer(minLength: 0)
                Text("\(ReplyLayoutCandidate.Sample.repo) — claude")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
                Spacer(minLength: 0)
                Text(ReplyLayoutCandidate.Sample.elapsed)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary)
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Notch.hairline).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Text("❯")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Notch.accent)
                    Text(ReplyLayoutCandidate.Sample.question)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Notch.text)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(
                        Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset
                    ) { _, tool in
                        HStack(spacing: 9) {
                            Text("$")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.Notch.textTertiary.opacity(0.6))
                            Text(tool.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.Notch.textSecondary)
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.Notch.success)
                            Spacer(minLength: 0)
                        }
                    }
                    Text(ReplyLayoutCandidate.Sample.code)
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.Notch.success)
                        .padding(.top, 4)
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text(ReplyLayoutCandidate.Sample.lead)
                        .font(Typography.sans(14, .regular, relativeTo: .body))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.Notch.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ReplyLayoutCandidate.Sample.tail)
                        .font(Typography.sans(14, .regular, relativeTo: .body))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.Notch.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)

                HStack(spacing: 8) {
                    Text("❯")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Notch.textTertiary)
                    Rectangle()
                        .fill(Theme.Notch.text.opacity(0.55))
                        .frame(width: 8, height: 15)
                    Spacer(minLength: 0)
                    Text("copy")
                    Text("open in kunai")
                    Text("esc")
                }
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Notch.textTertiary)
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
