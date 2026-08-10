import SwiftUI

/// Three layout directions for the finished turn, drawn side by side so one can be
/// chosen from a render rather than from a description.
///
/// **These are candidates, not shipping surfaces.** They carry sample content, no
/// measurement, and no state; only the direction that gets picked is built for
/// real and the other two are deleted. They live here rather than in the snapshot
/// renderer because they are views, and `SnapshotMode` should stay a driver.
enum ReplyLayoutCandidate {

    /// The content every candidate is drawn with, so the comparison is about the
    /// layout rather than about which one got the flattering paragraph.
    enum Sample {
        static let repo = "whisper-master"
        static let elapsed = "3m 12s"
        static let question = "Fix the flaky audio route test, and clear the build first."
        static let lead =
            "Cleared the build, then rewrote the route assertion to wait on the rebuilt "
            + "engine instead of a fixed delay. All 42 tests pass."
        static let code = """
            ✓ AudioRouteTests           42 passed   0 failed
            ✓ TranscriptMergerTests     18 passed   0 failed
            """
        static let tail =
            "The flake was the fixed delay racing the engine rebuild on slower runs, so "
            + "it only showed up under load."
        static let tools: [(glyph: String, text: String, ok: Bool)] = [
            ("checkmark", "❯ rm -rf build/", true),
            ("checkmark", "❯ swift test --filter AudioRoute", true),
            ("checkmark", "edit  Audio/RouteTests.swift", true),
        ]
        static let changed = ["Audio/RouteTests.swift"]
    }
}

// MARK: - A. Receipt

/// **A — Receipt.** The notch prints a slip. Narrow, centred, mono throughout, ruled
/// like something that came out of a machine. The run is a tallied list, the answer
/// is the body of the receipt, and the whole thing reads top to bottom in one column
/// with no decisions about where to look.
struct ReplyCandidateReceipt: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("WHISPER-MASTER")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Theme.Notch.text)
            Text("turn complete · \(ReplyLayoutCandidate.Sample.elapsed)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.Notch.textTertiary)
                .padding(.top, 5)
            perforation.padding(.vertical, 14)

            Text(ReplyLayoutCandidate.Sample.question)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Notch.accent)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 440)

            perforation.padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 9) {
                Text(ReplyLayoutCandidate.Sample.lead)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.Notch.text.opacity(0.92))
                Text(ReplyLayoutCandidate.Sample.code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Notch.success)
                    .lineSpacing(3)
                Text(ReplyLayoutCandidate.Sample.tail)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.Notch.text.opacity(0.92))
            }
            .frame(width: 468, alignment: .leading)

            perforation.padding(.vertical, 14)

            VStack(spacing: 6) {
                ForEach(Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset) {
                    _, tool in
                    HStack(spacing: 0) {
                        Text(tool.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.Notch.textSecondary)
                            .lineLimit(1)
                        Text(String(repeating: " ·", count: 40))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.Notch.hairline)
                            .lineLimit(1)
                            .layoutPriority(-1)
                        Text("ok")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.Notch.success)
                    }
                }
            }
            .frame(width: 468)

            perforation.padding(.vertical, 14)

            HStack(spacing: 18) {
                Text("copy")
                Text("open in kunai")
                Text("esc to close")
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(Theme.Notch.textTertiary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
    }

    private var perforation: some View {
        Text(String(repeating: "-", count: 78))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.Notch.text.opacity(0.16))
            .lineLimit(1)
            .frame(width: 468, alignment: .center)
    }
}

// MARK: - B. Editorial

/// **B — Editorial.** The question is a deck, set across the full width in display
/// type with a rule under it, the way a feature opens. The answer runs in one column
/// at a reading measure; the run sits in a right-hand margin as sidenotes. Reading
/// starts with your own words at full size, which is the thing that gives the answer
/// its meaning.
struct ReplyCandidateEditorial: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Theme.Notch.success).frame(width: 5, height: 5)
                Text(ReplyLayoutCandidate.Sample.repo.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.Notch.textTertiary)
                Spacer()
                Text(ReplyLayoutCandidate.Sample.elapsed)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Theme.Notch.textTertiary)
            }

            Text(ReplyLayoutCandidate.Sample.question)
                .font(Typography.heading(26, .semibold, relativeTo: .title))
                .tracking(Typography.trackingFor(26))
                .lineSpacing(4)
                .foregroundStyle(Theme.Notch.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.top, 22)

            Rectangle()
                .fill(Theme.Notch.accent)
                .frame(width: 54, height: 2)
                .padding(.top, 20)

            HStack(alignment: .top, spacing: 46) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(ReplyLayoutCandidate.Sample.lead)
                        .font(Typography.sans(14.5, .regular, relativeTo: .body))
                        .lineSpacing(6)
                        .foregroundStyle(Theme.Notch.text.opacity(0.93))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ReplyLayoutCandidate.Sample.code)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.Notch.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.04)))
                    Text(ReplyLayoutCandidate.Sample.tail)
                        .font(Typography.sans(14.5, .regular, relativeTo: .body))
                        .lineSpacing(6)
                        .foregroundStyle(Theme.Notch.text.opacity(0.93))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 620, alignment: .leading)

                VStack(alignment: .leading, spacing: 20) {
                    marginBlock("Ran") {
                        ForEach(
                            Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset
                        ) { _, tool in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.Notch.success)
                                    .frame(width: 10, alignment: .leading)
                                Text(tool.text)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.Notch.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    marginBlock("Changed") {
                        ForEach(ReplyLayoutCandidate.Sample.changed, id: \.self) { path in
                            Text(path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.Notch.textSecondary)
                        }
                    }
                    marginBlock("Take it with you") {
                        Text("copy answer")
                        Text("open in kunai")
                    }
                }
                .frame(width: 236, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.Notch.hairline).frame(width: 1).offset(x: -23)
                }
            }
            .padding(.top, 26)

            HStack {
                Spacer()
                Text("click anywhere, or esc, to close")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.7))
                Spacer()
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func marginBlock<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.Notch.textTertiary)
            VStack(alignment: .leading, spacing: 6) { content() }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.Notch.textSecondary)
        }
    }
}

// MARK: - C. Session log

/// **C — Session log.** The turn as it happened, in order, in one narrow column: your
/// line, then each tool call as it ran, then the answer — with a time gutter down the
/// left so the run reads as a sequence rather than as a summary. Nothing is a
/// container; the gutter and the ink weight carry the whole structure.
struct ReplyCandidateSessionLog: View {
    private let rows: [(time: String, kind: Kind, text: String)] = [
        ("00:00", .you, ReplyLayoutCandidate.Sample.question),
        ("00:01", .tool, "❯ rm -rf build/"),
        ("00:04", .tool, "❯ swift test --filter AudioRoute"),
        ("02:51", .tool, "edit  Audio/RouteTests.swift"),
        ("03:12", .answer, ReplyLayoutCandidate.Sample.lead),
        ("", .code, ReplyLayoutCandidate.Sample.code),
        ("", .answer, ReplyLayoutCandidate.Sample.tail),
    ]

    private enum Kind { case you, tool, answer, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(Theme.Notch.success).frame(width: 5, height: 5)
                Text(ReplyLayoutCandidate.Sample.repo)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
                Spacer()
                Text("copy")
                Text("open in kunai")
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.Notch.textTertiary)
            .padding(.bottom, 16)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    Text(row.time)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.Notch.textTertiary.opacity(0.65))
                        .frame(width: 46, alignment: .leading)
                    Rectangle()
                        .fill(gutterTint(row.kind))
                        .frame(width: 2)
                        .padding(.trailing, 16)
                    line(row.kind, row.text)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, row.kind == .code ? 12 : 11)
            }

            HStack {
                Spacer()
                Text("esc to close")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.7))
                Spacer()
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
    }

    private func gutterTint(_ kind: Kind) -> Color {
        switch kind {
        case .you: return Theme.Notch.accent
        case .tool: return Theme.Notch.hairline
        case .answer, .code: return Theme.Notch.success.opacity(0.7)
        }
    }

    @ViewBuilder
    private func line(_ kind: Kind, _ text: String) -> some View {
        switch kind {
        case .you:
            Text(text)
                .font(Typography.sans(15, .semibold, relativeTo: .body))
                .lineSpacing(4)
                .foregroundStyle(Theme.Notch.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 640, alignment: .leading)
        case .tool:
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Notch.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 640, alignment: .leading)
        case .answer:
            Text(text)
                .font(Typography.sans(14, .regular, relativeTo: .body))
                .lineSpacing(5)
                .foregroundStyle(Theme.Notch.text.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 640, alignment: .leading)
        case .code:
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(4)
                .foregroundStyle(Theme.Notch.success)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 640, alignment: .leading)
        }
    }
}
