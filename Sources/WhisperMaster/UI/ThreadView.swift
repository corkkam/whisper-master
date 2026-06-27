import SwiftUI

/// The dictation "thread": one continuous line that lives in the notch band.
///
/// While listening it's a travelling, audio-reactive wave. When the app is busy
/// (preparing models, loading an engine, finalizing) it folds into a slowly
/// spinning ring — the same thread, curled into a loop — so there's a single
/// visual language instead of a separate spinner.
///
/// The fold is driven by time (not SwiftUI's implicit animation) so it can
/// coexist with the per-frame `TimelineView` that animates the wave, and it
/// resolves interrupted transitions cleanly.
struct ThreadView: View {
    let level: Float
    /// `true` curls the thread into a spinning ring; `false` is the open wave.
    var folded: Bool

    var width: CGFloat = 150
    var lineWidth: CGFloat = 2.5
    /// Sine cycles drawn along the thread.
    var cycles: CGFloat = 2.2
    /// Wave amplitude when idle vs. at full speech.
    var idleAmplitude: CGFloat = 2
    var maxAmplitude: CGFloat = 8

    private let foldDuration: Double = 0.55
    private let waveSpeed: Double = 3.0   // travelling-wave phase
    private let spinSpeed: Double = 3.4   // ring rotation (rad/s)
    /// Fraction of the ring left open, giving the spinner its rotating gap.
    private let gapFraction: CGFloat = 0.16

    @State private var startMorph: Double = 0
    @State private var endMorph: Double = 0
    @State private var transitionStart: Date = .distantPast

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date
            let morph = morph(at: now)
            let t = now.timeIntervalSinceReferenceDate

            Canvas { ctx, size in
                let path = threadPath(in: size, time: t, morph: morph)
                ctx.stroke(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: 0, y: size.height / 2),
                        endPoint: CGPoint(x: size.width, y: size.height / 2)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
            .frame(width: width)
        }
        .onAppear {
            let value: Double = folded ? 1 : 0
            startMorph = value
            endMorph = value
        }
        .onChange(of: folded) { _, isFolded in
            let now = Date()
            startMorph = morph(at: now)
            endMorph = isFolded ? 1 : 0
            transitionStart = now
        }
    }

    // MARK: - Morph progress (time-based, interruption-safe)

    private func morph(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(transitionStart)
        guard elapsed < foldDuration else { return endMorph }
        let progress = max(0, elapsed / foldDuration)
        let eased = progress * progress * (3 - 2 * progress) // smoothstep
        return startMorph + (endMorph - startMorph) * eased
    }

    // MARK: - Geometry

    /// Interpolates each point of the thread between its position on the open
    /// wave and its position on the spinning arc, by `morph` (0 = wave, 1 = ring).
    ///
    /// As the thread folds, the wave both **contracts** (its width shrinks toward
    /// the arc's length) and **flattens** (amplitude fades), so the line never
    /// has to bunch up to wrap the much smaller ring — that's what kept the old
    /// fold looking messy.
    private func threadPath(in size: CGSize, time: Double, morph: Double) -> Path {
        let steps = 140
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ringRadius = min(size.width, size.height) / 2 - lineWidth

        let speech = min(1, max(0, CGFloat(level) * 18))
        let waveAmplitude = (idleAmplitude + (maxAmplitude - idleAmplitude) * speech) * CGFloat(1 - morph)
        let phase = CGFloat(time * waveSpeed)
        let spin = CGFloat(time * spinSpeed)

        // Arc swept by the ring (a gap is left open for the spinner look).
        let span = (1 - gapFraction) * 2 * .pi
        let arcLength = span * ringRadius
        let effectiveWidth = width + (arcLength - width) * CGFloat(morph)

        var path = Path()
        for step in 0...steps {
            let f = CGFloat(step) / CGFloat(steps)
            let wiggle = sin(f * cycles * 2 * .pi + phase)

            // Open wave: contracted width, tapered to flat at the ends.
            let waveX = center.x + (f - 0.5) * effectiveWidth
            let waveY = center.y + waveAmplitude * CGFloat(sin(Double(f) * .pi)) * wiggle

            // Spinning arc: centered, with a rotating open gap.
            let angle = (f - 0.5) * span + spin - .pi / 2
            let ringX = center.x + ringRadius * cos(angle)
            let ringY = center.y + ringRadius * sin(angle)

            let point = CGPoint(
                x: waveX + (ringX - waveX) * CGFloat(morph),
                y: waveY + (ringY - waveY) * CGFloat(morph)
            )

            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private var gradient: Gradient {
        Gradient(colors: [
            Color(red: 0.55, green: 0.85, blue: 1.0),
            .white,
            Color(red: 0.55, green: 0.85, blue: 1.0)
        ])
    }
}
