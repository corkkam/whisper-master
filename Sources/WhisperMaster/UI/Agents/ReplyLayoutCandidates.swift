import SwiftUI

/// Layout directions for the finished turn, drawn so one can be chosen from a
/// render rather than from a description.
///
/// **These are candidates, not shipping surfaces.** They carry sample content, no
/// measurement, and no state; only the direction that gets picked is built for real
/// and the rest are deleted.
///
/// Round one arranged type with hairlines. Round two changed the material to tiles,
/// columns, colour and window chrome. Round three went quiet — margins, a thread,
/// paper. This round attacks the *hierarchy*: what if the answer is the headline
/// rather than the question, what if the frame is an instrument, what if the page is
/// ruled, what if almost all of it is empty.
enum ReplyLayoutCandidate {

    /// The content every candidate is drawn with, so the comparison is about the
    /// layout rather than about which one got the flattering paragraph.
    enum Sample {
        static let repo = "whisper-master"
        static let elapsed = "3m 12s"
        static let question = "Fix the flaky audio route test, and clear the build first."
        /// The answer's opening sentence, which is almost always the whole verdict.
        static let verdict = "Cleared the build, then rewrote the route assertion to wait on the rebuilt engine."
        static let lead =
            "The flake was the fixed delay racing the engine rebuild on slower runs, so it "
            + "only showed up under load. Both suites are green on the rebuilt engine now."
        static let code = """
            ✓ AudioRouteTests           42 passed   0 failed
            ✓ TranscriptMergerTests     18 passed   0 failed
            """
        static let tools: [(time: String, text: String)] = [
            ("00:01", "rm -rf build/"),
            ("00:04", "swift test --filter AudioRoute"),
            ("02:51", "edit  Audio/RouteTests.swift"),
        ]
        static let changed = ["Audio/RouteTests.swift"]
        static let runIndex = "rm -rf build/  ·  swift test --filter AudioRoute  ·  edit RouteTests.swift"
    }
}

// MARK: - K. Verdict

/// **K — Verdict.** Every candidate so far made the question the headline. But you
/// already know what you asked; what you came back for is the answer. So the answer's
/// opening sentence *is* the headline, set large, and the question shrinks to a
/// single ember line above it. Everything else — the detail, the output, the run —
/// falls away underneath at supporting size.
struct ReplyCandidateVerdict: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 8.5, weight: .bold))
                Text(ReplyLayoutCandidate.Sample.question)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 20)
                Text("\(ReplyLayoutCandidate.Sample.repo)  ·  \(ReplyLayoutCandidate.Sample.elapsed)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary)
            }
            .foregroundStyle(Theme.Notch.accent)

            Text(ReplyLayoutCandidate.Sample.verdict)
                .font(Typography.heading(27, .semibold, relativeTo: .title))
                .tracking(Typography.trackingFor(27))
                .lineSpacing(5)
                .foregroundStyle(Theme.Notch.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 700, alignment: .leading)
                .padding(.top, 22)

            HStack(alignment: .top, spacing: 44) {
                Text(ReplyLayoutCandidate.Sample.lead)
                    .font(Typography.sans(13.5, .regular, relativeTo: .body))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 420, alignment: .leading)
                Text(ReplyLayoutCandidate.Sample.code)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.Notch.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26)

            Spacer(minLength: 30)

            HStack(spacing: 0) {
                ForEach(Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset) {
                    index, tool in
                    if index > 0 {
                        Text("·")
                            .foregroundStyle(Theme.Notch.textTertiary.opacity(0.5))
                            .padding(.horizontal, 10)
                    }
                    Text(tool.text)
                        .foregroundStyle(Theme.Notch.textTertiary.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 24)
                Text("copy")
                Text("kunai").padding(.leading, 16)
                Text("esc").padding(.leading, 16)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.Notch.textTertiary.opacity(0.75))
            .padding(.top, 18)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Notch.hairline).frame(height: 1).offset(y: -9)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 22)
    }
}

// MARK: - L. Plate

/// **L — Plate.** The turn presented as a drawing on a plate: thin ember corner
/// brackets holding the content like a viewfinder, dimension ticks along the top
/// edge, and the session name set *vertically* down the left margin in tracked caps.
/// Precise rather than decorative — the elegance of an instrument panel, where every
/// mark is a measurement.
struct ReplyCandidatePlate: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(ReplyLayoutCandidate.Sample.repo.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(3.4)
                .foregroundStyle(Theme.Notch.textTertiary)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 22)
                .padding(.top, 130)

            VStack(alignment: .leading, spacing: 0) {
                ticks
                    .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("QUERY")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(2.2)
                            .foregroundStyle(Theme.Notch.accent)
                        Text(ReplyLayoutCandidate.Sample.question)
                            .font(Typography.sans(16, .semibold, relativeTo: .body))
                            .foregroundStyle(Theme.Notch.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("RESULT")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(2.2)
                            .foregroundStyle(Theme.Notch.success)
                        Text(ReplyLayoutCandidate.Sample.verdict + " " + ReplyLayoutCandidate.Sample.lead)
                            .font(Typography.sans(14, .regular, relativeTo: .body))
                            .lineSpacing(6)
                            .foregroundStyle(Theme.Notch.text.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 620, alignment: .leading)
                        Text(ReplyLayoutCandidate.Sample.code)
                            .font(.system(size: 11, design: .monospaced))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.Notch.success)
                            .padding(.top, 4)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay { CornerBrackets(length: 18, inset: 0).stroke(Theme.Notch.accent.opacity(0.75), lineWidth: 1.2) }

                HStack(spacing: 0) {
                    ForEach(Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset) {
                        index, tool in
                        Text(String(format: "%02d", index + 1))
                            .foregroundStyle(Theme.Notch.textTertiary.opacity(0.55))
                            .padding(.trailing, 7)
                        Text(tool.text)
                            .foregroundStyle(Theme.Notch.textSecondary)
                            .lineLimit(1)
                        if index < ReplyLayoutCandidate.Sample.tools.count - 1 {
                            Spacer(minLength: 18)
                        }
                    }
                    Spacer(minLength: 24)
                    Text(ReplyLayoutCandidate.Sample.elapsed)
                        .foregroundStyle(Theme.Notch.text)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.top, 18)
            }
            .padding(.trailing, 34)
        }
        .padding(.leading, 22)
        .padding(.top, 26)
        .padding(.bottom, 24)
    }

    /// A measured edge: long tick, four short, repeating. It says "this surface is
    /// calibrated" without printing a single number.
    private var ticks: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(0..<44, id: \.self) { index in
                Rectangle()
                    .fill(Theme.Notch.text.opacity(index % 5 == 0 ? 0.28 : 0.12))
                    .frame(width: 1, height: index % 5 == 0 ? 9 : 5)
            }
            Spacer(minLength: 0)
        }
    }

    private struct CornerBrackets: Shape {
        let length: CGFloat
        let inset: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let r = rect.insetBy(dx: inset, dy: inset)
            for (corner, dx, dy) in [
                (CGPoint(x: r.minX, y: r.minY), CGFloat(1), CGFloat(1)),
                (CGPoint(x: r.maxX, y: r.minY), CGFloat(-1), CGFloat(1)),
                (CGPoint(x: r.minX, y: r.maxY), CGFloat(1), CGFloat(-1)),
                (CGPoint(x: r.maxX, y: r.maxY), CGFloat(-1), CGFloat(-1)),
            ] {
                path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            }
            return path
        }
    }
}

// MARK: - M. Ruled

/// **M — Ruled.** The answer is written on a ruled sheet: faint baselines running the
/// full width, the text sitting on them, the question above as a heading with a short
/// ember underline. The rules are the only ornament, and because they are horizontal
/// and continuous they make the band feel like a *page* laid under the notch rather
/// than a panel bolted to it.
struct ReplyCandidateRuled: View {
    private let ruleSpacing: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(ReplyLayoutCandidate.Sample.question)
                    .font(Typography.heading(20, .semibold, relativeTo: .title3))
                    .tracking(Typography.trackingFor(20))
                    .foregroundStyle(Theme.Notch.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Text("\(ReplyLayoutCandidate.Sample.elapsed)  ·  \(ReplyLayoutCandidate.Sample.repo)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary)
            }
            Rectangle()
                .fill(Theme.Notch.accent)
                .frame(width: 44, height: 2)
                .padding(.top, 11)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { _ in
                        Rectangle()
                            .fill(Theme.Notch.text.opacity(0.055))
                            .frame(height: 1)
                            .frame(height: ruleSpacing, alignment: .bottom)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(ReplyLayoutCandidate.Sample.verdict)
                        .font(Typography.sans(15, .medium, relativeTo: .body))
                        .foregroundStyle(Theme.Notch.text)
                        .lineSpacing(ruleSpacing - 18)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ReplyLayoutCandidate.Sample.lead)
                        .font(Typography.sans(15, .regular, relativeTo: .body))
                        .foregroundStyle(Theme.Notch.text.opacity(0.86))
                        .lineSpacing(ruleSpacing - 18)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }
                .frame(width: 660, alignment: .leading)
                .padding(.top, 4)
            }
            .padding(.top, 20)

            HStack(alignment: .top, spacing: 34) {
                Text(ReplyLayoutCandidate.Sample.code)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.Notch.success)
                    .padding(.leading, 15)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.Notch.success.opacity(0.45)).frame(width: 2)
                    }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(ReplyLayoutCandidate.Sample.tools.enumerated()), id: \.offset) {
                        _, tool in
                        HStack(spacing: 9) {
                            Text(tool.time)
                                .foregroundStyle(Theme.Notch.textTertiary.opacity(0.6))
                            Text(tool.text)
                                .foregroundStyle(Theme.Notch.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .padding(.top, 22)

            HStack {
                Spacer()
                Text("copy  ·  kunai  ·  esc")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.7))
                Spacer()
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 38)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }
}

// MARK: - N. Quiet

/// **N — Quiet.** Almost all of it is empty. The content sits in a single narrow
/// column pushed well right of centre; the whole left third holds one ember dot, the
/// elapsed time, and nothing else. A finished turn is a small event, and a surface
/// that behaves like one — mostly black, one column, generous type — is calmer to
/// have drop over a video than any amount of well-arranged information.
struct ReplyCandidateQuiet: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Circle()
                    .fill(Theme.Notch.accent)
                    .frame(width: 7, height: 7)
                Text(ReplyLayoutCandidate.Sample.elapsed)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
                Text(ReplyLayoutCandidate.Sample.repo)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.8))
                Spacer(minLength: 0)
                Text("copy\nkunai\nesc")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.6))
            }
            .frame(width: 250, alignment: .leading)

            VStack(alignment: .leading, spacing: 24) {
                Text(ReplyLayoutCandidate.Sample.question)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(Theme.Notch.accent)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ReplyLayoutCandidate.Sample.verdict)
                    .font(Typography.sans(17, .regular, relativeTo: .body))
                    .lineSpacing(9)
                    .foregroundStyle(Theme.Notch.text)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ReplyLayoutCandidate.Sample.code)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.Notch.success)

                Text(ReplyLayoutCandidate.Sample.lead)
                    .font(Typography.sans(14, .regular, relativeTo: .body))
                    .lineSpacing(7)
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ReplyLayoutCandidate.Sample.runIndex)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary.opacity(0.55))
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            .frame(width: 470, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.leading, 44)
        .padding(.trailing, 40)
        .padding(.top, 40)
        .padding(.bottom, 34)
    }
}
