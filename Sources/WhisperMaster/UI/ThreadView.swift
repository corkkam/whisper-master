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
/// resolves interrupted transitions cleanly. The palette is the warm brand
/// `Theme.Notch.waveGradient` (cream → white → vermillion), not the old cold
/// blue. When Reduce Motion is on the travelling wave + spin are dropped for a
/// static shape with a slow opacity pulse.
struct ThreadView: View {
    let level: Float
    /// `true` curls the thread into a spinning ring; `false` is the open wave.
    var folded: Bool

    var width: CGFloat = 96
    var lineWidth: CGFloat = 2.0
    /// Slightly thicker stroke once curled, so the ring reads as a real spinner
    /// inside the slim band.
    var ringLineWidth: CGFloat = 3.2
    /// Fixed ring radius — big enough to be visible in the 24-pt band, instead of
    /// the old height-clamped radius that collapsed the spinner to a dot.
    var ringRadius: CGFloat = 10
    /// Sine cycles drawn along the thread.
    var cycles: CGFloat = 1.5
    /// Wave amplitude when idle vs. at full speech.
    var idleAmplitude: CGFloat = 1.5
    var maxAmplitude: CGFloat = 6

    private let foldDuration: Double = 0.55
    private let waveSpeed: Double = 3.0   // travelling-wave phase
    private let spinSpeed: Double = 3.4   // ring rotation (rad/s)
    private let breatheSpeed: Double = 1.7 // idle amplitude undulation
    /// Fraction of the ring left open, giving the spinner its rotating gap.
    private let gapFraction: CGFloat = 0.16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startMorph: Double = 0
    @State private var endMorph: Double = 0
    @State private var transitionStart: Date = .distantPast
    /// Entry pop (non-reduced path) and slow opacity pulse (reduced path).
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        Group {
            if reduceMotion {
                // No continuous TimelineView motion — a single static render with
                // a gentle opacity pulse so the line still looks alive.
                waveCanvas(time: 0, morph: folded ? 1 : 0)
                    .opacity(pulse ? 1 : 0.5)
            } else {
                TimelineView(.animation) { context in
                    let now = context.date
                    waveCanvas(time: now.timeIntervalSinceReferenceDate, morph: morph(at: now))
                }
                // Entry pop: the thread announces itself when listening starts.
                .scaleEffect(appeared ? 1 : 0.86)
                .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear(perform: handleAppear)
        .onChange(of: folded, handleFoldChange)
    }

    // MARK: - Rendering

    /// The shared stroke, used by both the animated and reduced paths.
    private func waveCanvas(time: Double, morph: Double) -> some View {
        Canvas { ctx, size in
            let path = threadPath(in: size, time: time, morph: morph)
            // Thicken toward the ring so the spinner reads within the slim band.
            let stroke = lineWidth + (ringLineWidth - lineWidth) * CGFloat(morph)
            ctx.stroke(
                path,
                with: .linearGradient(
                    Theme.Notch.waveGradient,
                    startPoint: CGPoint(x: 0, y: size.height / 2),
                    endPoint: CGPoint(x: size.width, y: size.height / 2)
                ),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: width)
    }

    // MARK: - Lifecycle

    private func handleAppear() {
        let value: Double = folded ? 1 : 0
        startMorph = value
        endMorph = value
        if reduceMotion {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(Theme.Motion.appear) { appeared = true }
        }
    }

    private func handleFoldChange(_ wasFolded: Bool, _ isFolded: Bool) {
        let now = Date()
        startMorph = morph(at: now)
        endMorph = isFolded ? 1 : 0
        transitionStart = now
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
        // Fixed radius, clamped only if the band is somehow shorter than it.
        let ringRadius = min(self.ringRadius, size.height / 2 - ringLineWidth / 2)

        let speech = min(1, max(0, CGFloat(level) * 18))
        // Idle breathing: with little speech, swell/recede the baseline amplitude
        // so pauses show a living undulation rather than a dead flat line. It's
        // swamped by real speech (which drives straight to `maxAmplitude`).
        let breathe = 0.6 + 0.4 * CGFloat(sin(time * breatheSpeed)) // ~0.2…1.0
        let idleAmp = idleAmplitude * breathe
        let liveAmplitude = idleAmp + (maxAmplitude - idleAmp) * speech
        let waveAmplitude = liveAmplitude * CGFloat(1 - morph)
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
}
