import AppKit
import SwiftUI

/// First-run setup, in the notch.
///
/// One black `NotchShape` molded to the physical notch, holding a single ask at
/// a time: the step dots, the orb, one headline, one body and one action row.
/// Setup therefore happens on exactly the surface dictation will live on — the
/// user learns where to look while they're granting.
///
/// The orb is the only perpetual mover. Every other layer plays once and holds:
/// each frame is a pure function of the model's clock and timestamps (see
/// `OnboardingMotion.swift`), so the snapshot renderer can draw any instant.
struct NotchOnboardingView: View {
    let model: NotchOnboardingModel
    /// Read-only, for the push-to-talk key's name and form.
    let state: AppState
    var geometry: NotchGeometry = .none
    var layout: NotchOnboardingLayout = NotchOnboardingLayout()
    /// Opens the Settings window — the gear in the top row.
    var onOpenSettings: () -> Void = {}
    /// The orb's instant, for a snapshot (`0.6 + elapsed`). Nil runs the wall clock.
    var orbTime: Double? = nil
    /// Runs when the band's content appears. Nil in the app; the identity test
    /// counts it to prove the timeline below is never added or removed.
    var onContentAppear: (() -> Void)? = nil

    var body: some View {
        // One timeline for the band's whole life, paused at rest. Adding or
        // removing it would change the content's identity, which resets the
        // focused button and VoiceOver focus.
        TimelineView(.animation(minimumInterval: nil, paused: isPaused)) { _ in
            frame(at: model.clock.now())
                .onAppear { onContentAppear?() }
        }
        .onAppear { model.refresh() }
        // The permission poll deliberately lives in `NotchOnboardingWindow`, not
        // here: a `Timer.publish` created in this body would be re-subscribed on
        // every body pass, and the mic check re-evaluates it ~20×/s, so the tick
        // would be starved exactly when the flow depends on it.
    }

    private var isPaused: Bool {
        model.clock.isFixed || model.clock.now() >= model.activeUntil
    }

    private var copy: OnboardingCopy {
        OnboardingCopy(
            key: state.hotkey, holdToTalk: state.holdToTalkEnabled, orbIsStatic: model.policy.orbIsStatic,
            canRetryEngine: model.onRetryEngine != nil)
    }

    // MARK: Frame

    private func frame(at now: TimeInterval) -> some View {
        let f = BandFrame(model: model, copy: copy, now: now)
        let surfaceWidth = layout.surfaceWidth(for: geometry)
        let notchBody = geometry.hasNotch ? geometry.notchWidth : layout.fallbackBodyWidth
        let shape = NotchShape(
            topConcaveRadius: layout.topConcaveRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        )

        return VStack(spacing: 0) {
            // Camera dead-zone — nothing renders behind the physical notch, and
            // clicks up there fall through to the menu bar.
            Color.clear
                .frame(height: geometry.notchHeight)
                .allowsHitTesting(false)

            band(f)
                // Laid out at full size, so a fold clips the content rather than
                // re-wrapping it.
                .frame(width: surfaceWidth, height: layout.thickness)
        }
        .frame(
            width: surfaceWidth + (notchBody - surfaceWidth) * CGFloat(f.fold),
            height: geometry.notchHeight + layout.thickness * CGFloat(1 - f.fold),
            alignment: .top
        )
        .background { shape.fill(Theme.Notch.surface) }
        .clipShape(shape)
        // The band is always ink, whatever the app's appearance is set to, so the
        // button ladder inside it has to read from `Theme.Notch` rather than the
        // mode-dependent tokens. Declared once here for the whole subtree.
        .onDarkSurface()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Band

    private func band(_ f: BandFrame) -> some View {
        let current = copy.screen(model.bandState)
        return VStack(spacing: 0) {
            topBar
                .layer(f.chrome)
            StepDots(
                current: model.step.rawValue,
                from: f.beadFrom,
                slide: f.bead,
                isDone: { stepIsDone($0) },
                bead: beadColor
            )
            .padding(.top, 2)
            .layer(f.chrome)

            // A fixed slot: the orb itself is drawn over it at `orbCenterY`, so
            // the stage's fold lands on exactly this point.
            Color.clear
                .frame(width: layout.orbDiameter, height: layout.orbDiameter)
                .padding(.top, Theme.Space.sm)

            ZStack(alignment: .top) {
                if let previous = f.previous {
                    copyBlock(copy.screen(previous.state), layers: previous.layers, cap: 1, ring: 1, glyph: 1)
                }
                copyBlock(current, layers: f.incoming, cap: f.rowCap, ring: f.ring, glyph: f.glyph)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.lg)
        .padding(.horizontal, Theme.Space.xl)
        .opacity(f.content)
        .background(alignment: .top) { bloom(f) }
        .overlay(alignment: .top) { orb(f) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OnboardingCopy.bandLabel(model.step))
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.md) {
            Spacer()
            NotchIconButton(icon: "gearshape.fill", label: OnboardingCopy.settingsLabel, action: onOpenSettings)
            NotchIconButton(icon: "xmark", label: OnboardingCopy.closeAccessibilityLabel, action: model.dismiss)
        }
    }

    /// The orb, drawn over its slot so the outro can resize it toward the notch
    /// without moving the rows. Hidden from VoiceOver: the headline carries the
    /// meaning.
    private func orb(_ f: BandFrame) -> some View {
        OrbView(
            level: model.level,
            mode: f.figure,
            diameter: f.orbDiameter,
            preset: .large,
            entrance: false,
            time: orbTime,
            staticFrame: model.policy.orbIsStatic,
            gain: OnboardingOrbGain.resolve(
                micCheckRunning: model.micCheckRunning, heardAt: model.heardAt, now: f.now, level: model.level),
            gather: f.orbGather
        )
        .scaleEffect(f.dip.scale)
        .opacity(f.dip.opacity)
        .offset(y: layout.orbCenterY + (-geometry.notchHeight / 2 - layout.orbCenterY) * CGFloat(f.fold)
            - f.orbDiameter / 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The soft glow a live grant raises behind the orb: the `NotchGlow` stop
    /// ladder, capped at `bloomAlpha`. It never pulses.
    private func bloom(_ f: BandFrame) -> some View {
        let tint = f.bloomHue == .voice ? Theme.Notch.accent : Theme.Notch.success
        return EllipticalGradient(
            stops: [
                .init(color: tint.opacity(f.bloom), location: 0),
                .init(color: tint.opacity(f.bloom * 0.34), location: 0.32),
                .init(color: tint.opacity(f.bloom * 0.10), location: 0.62),
                .init(color: .clear, location: 1),
            ],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
        .frame(width: layout.bloomSize.width, height: layout.bloomSize.height)
        .offset(y: layout.orbCenterY - layout.bloomSize.height / 2)
        .opacity(f.bloom > 0 ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Copy

    /// Headline, body and action row for one state. Written as the app speaking,
    /// one idea per sentence: the band has room for two lines, not a paragraph.
    private func copyBlock(
        _ screen: OnboardingScreen, layers: CopyLayers, cap: Double, ring: Double, glyph: Double
    ) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(screen.headline)
                    .font(Typography.sans(19, .bold))
                    .foregroundStyle(Theme.Notch.text)
                    .accessibilityAddTraits(.isHeader)
                    .layer(layers.headline)
                Text(Self.fitting(screen, width: layout.bodyFitWidth))
                    .font(Typography.sans(13))
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .layer(layers.body)
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.top, Theme.Space.md)
            .padding(.horizontal, Theme.Space.lg)

            row(screen.row, ring: ring, glyph: glyph)
                .padding(.top, Theme.Space.lg)
                // Until input opens the row draws at half opacity at most.
                .layer(OnboardingLayer(
                    opacity: min(layers.actions.opacity, cap), x: layers.actions.x, y: layers.actions.y))
        }
    }

    /// Whether a body fits two lines, by body text and width. The answer never
    /// changes for a string, and the band redraws every frame while it moves.
    @MainActor private static var fitsTwoLines: [String: Bool] = [:]

    /// The body, or its shorter form when the body runs past two lines at the
    /// fit tests' measure. The panel never grows, so copy gives way first.
    @MainActor
    static func fitting(_ screen: OnboardingScreen, width: CGFloat) -> String {
        guard let fallback = screen.fallbackBody, !fallback.isEmpty else { return screen.body }
        let key = "\(width)|\(screen.body)"
        if let fits = fitsTwoLines[key] { return fits ? screen.body : fallback }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: BrandFont.body])
        let font = NSFont(descriptor: descriptor, size: 13) ?? .systemFont(ofSize: 13)
        let text = NSAttributedString(string: screen.body, attributes: [.font: font])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 10_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = (CTFrameGetLines(frame) as? [CTLine])?.count ?? 0
        fitsTwoLines[key] = lines <= 2
        return lines <= 2 ? screen.body : fallback
    }

    @ViewBuilder
    private func row(_ row: OnboardingRow, ring: Double, glyph: Double) -> some View {
        switch row {
        case .buttons(let buttons):
            HStack(spacing: Theme.Space.sm) {
                ForEach(Array(buttons.enumerated()), id: \.element) { index, button in
                    // One primary per state: the main button. A lone Not now is
                    // the way past, not an ask, so it stays outlined.
                    let primary = index == 0 && button != .notNow
                    NotchPillButton(title: button.title, kind: primary ? .primary : .ghost) {
                        model.perform(button)
                    }
                }
            }
        case .waiting:
            HStack(spacing: Theme.Space.sm) {
                Text(OnboardingCopy.waitingLine)
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.textSecondary)
                NotchPillButton(title: OnboardingButton.notNow.title, kind: .ghost) { model.perform(.notNow) }
            }
        case .badge(let text, let done):
            HStack(spacing: Theme.Space.sm) {
                GrantedBadge(text: text, ring: ring, glyph: glyph)
                switch done {
                case .movingOn:
                    Text(OnboardingCopy.movingOnLine.text)
                        .font(Typography.notchBody)
                        .foregroundStyle(Theme.Notch.textTertiary)
                case .waits:
                    NotchPillButton(title: OnboardingButton.continue.title) { model.perform(.continue) }
                case .paused:
                    if let line = OnboardingCopy.pausedLine.text.nilIfEmpty {
                        Text(line)
                            .font(Typography.notchBody)
                            .foregroundStyle(Theme.Notch.textTertiary)
                    }
                    NotchPillButton(title: OnboardingButton.continue.title) { model.perform(.continue) }
                }
            }
        }
    }

    // MARK: Step dots

    private func stepIsDone(_ step: NotchOnboardingStep) -> Bool {
        OnboardingCopy.stepIsDone(
            step, micOn: model.micGranted, typingOn: model.accessibilityGranted,
            loginOn: model.launchAtLoginEnabled)
    }

    /// Ember for the current step, warning while its ask was refused or failed.
    private var beadColor: Color {
        switch model.bandState {
        case .micDenied, .micFailed, .loginFailed, .ready(.micDenied), .ready(.loadingMicDenied), .ready(.failed):
            return Theme.Notch.warning
        default:
            return Theme.Notch.accent
        }
    }
}

// MARK: - Frame composition

/// The three layers of one block of copy.
private struct CopyLayers {
    var headline = OnboardingLayer.rest
    var body = OnboardingLayer.rest
    var actions = OnboardingLayer.rest

    static let rest = CopyLayers()

    init(headline: OnboardingLayer = .rest, body: OnboardingLayer = .rest, actions: OnboardingLayer = .rest) {
        self.headline = headline
        self.body = body
        self.actions = actions
    }

    init(all layer: OnboardingLayer) {
        self.init(headline: layer, body: layer, actions: layer)
    }

    func combined(with other: CopyLayers) -> CopyLayers {
        CopyLayers(headline: headline.combined(with: other.headline), body: body.combined(with: other.body),
                   actions: actions.combined(with: other.actions))
    }
}

/// Every running cue, composed into one frame of the band at `now`. With every
/// timestamp nil it is the band at rest.
private struct BandFrame {
    let now: TimeInterval
    var chrome = OnboardingLayer.rest
    var incoming = CopyLayers.rest
    /// The copy on its way out: the old beat, or the old state inside a beat.
    var previous: (state: OnboardingState, layers: CopyLayers)?
    var rowCap: Double = 1
    var beadFrom: Int
    var bead: Double = 1
    var ring: Double = 1
    var glyph: Double = 1
    var bloom: Double = 0
    var bloomHue: OnboardingBloom.Hue?
    var figure: OrbFigure
    var dip = OrbDip.rest
    var orbGather: Double = 1
    var orbDiameter: CGFloat
    var content: Double = 1
    var fold: Double = 0

    @MainActor
    init(model: NotchOnboardingModel, copy: OnboardingCopy, now: TimeInterval) {
        self.now = now
        let policy = model.policy
        beadFrom = model.step.rawValue
        figure = model.orbFigure
        orbDiameter = NotchOnboardingLayout().orbDiameter

        if let start = model.revealStartedAt {
            let reveal = BandReveal.frame(at: now - start, gathers: model.revealGathers, policy: policy)
            chrome = reveal.chrome
            incoming = CopyLayers(headline: reveal.headline, body: reveal.body, actions: reveal.actions)
            rowCap = min(rowCap, reveal.rowCap)
            orbGather = reveal.orbGather
        }

        if let change = model.beatChange {
            let beat = BeatTransition.frame(at: now - change.at, policy: policy)
            incoming = incoming.combined(with: CopyLayers(headline: beat.headline, body: beat.body, actions: beat.actions))
            previous = (change.previous, CopyLayers(all: beat.outgoing))
            rowCap = min(rowCap, beat.rowCap)
            beadFrom = change.previous.step.rawValue
            bead = beat.bead
            if let hue = change.heldBloom, policy.layers == .full {
                bloom = Theme.Notch.bloomAlpha * beat.outgoing.opacity
                bloomHue = hue
            }
        }

        if let hue = model.heldBloom, policy.layers == .full {
            bloomHue = hue
            bloom = Theme.Notch.bloomAlpha
        }

        if let change = model.rowChange {
            let elapsed = now - change.at
            let flourish = Flourish.frame(at: elapsed, policy: policy)
            let old = copy.screen(change.previous)
            let new = copy.screen(model.bandState)
            // Text that did not change does not cross-fade, or it would dip.
            let headlineSame = old.headline == new.headline
            let bodySame = old.body == new.body
            func layer(_ opacity: Double, same: Bool, old: Bool) -> OnboardingLayer {
                OnboardingLayer(opacity: same ? (old ? 0 : 1) : opacity)
            }
            incoming = incoming.combined(with: CopyLayers(
                headline: layer(flourish.newCopy, same: headlineSame, old: false),
                body: layer(flourish.newCopy, same: bodySame, old: false),
                actions: OnboardingLayer(opacity: flourish.newRow)))
            previous = (change.previous, CopyLayers(
                headline: layer(flourish.oldCopy, same: headlineSame, old: true),
                body: layer(flourish.oldCopy, same: bodySame, old: true),
                actions: OnboardingLayer(opacity: flourish.oldRow)))
            rowCap = min(rowCap, flourish.rowCap)
            if change.grant {
                ring = flourish.ring
                glyph = flourish.glyph
                if model.heldBloom != nil {
                    bloom = OnboardingBloom.alpha(at: elapsed, liveGrant: true, policy: policy)
                }
            }
        }

        if let dip = model.dip {
            self.dip = OrbDip.frame(at: now - dip.at, from: dip.start, policy: policy)
            if !self.dip.figureIsNew { figure = dip.from }
        }

        if let start = model.outroStartedAt {
            let outro = Outro.frame(at: now - start)
            content = outro.content
            bloom *= outro.content
            fold = outro.fold
            orbGather = min(orbGather, outro.orbGather)
            orbDiameter *= CGFloat(1 - outro.fold)
        }
    }
}

private extension OnboardingLayer {
    /// Two cues on one layer: opacities multiply, offsets add.
    func combined(with other: OnboardingLayer) -> OnboardingLayer {
        OnboardingLayer(opacity: opacity * other.opacity, x: x + other.x, y: y + other.y)
    }
}

private extension View {
    func layer(_ layer: OnboardingLayer) -> some View {
        opacity(layer.opacity).offset(x: layer.x, y: layer.y)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Pieces

/// The step counter: one capsule per beat. Past steps read signal when done and
/// tertiary when skipped, future steps `futureStep`, and the current one is the
/// ember bead, which slides from the old step to the new one.
private struct StepDots: View {
    let current: Int
    let from: Int
    let slide: Double
    let isDone: (NotchOnboardingStep) -> Bool
    let bead: Color

    private static let width: CGFloat = 30
    private static let gap: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: Self.gap) {
                ForEach(NotchOnboardingStep.allCases, id: \.self) { step in
                    Capsule(style: .continuous)
                        .fill(fill(step))
                        .frame(width: Self.width, height: 3)
                }
            }
            Capsule(style: .continuous)
                .fill(bead)
                .frame(width: Self.width, height: 3)
                .offset(x: (Self.width + Self.gap) * CGFloat(Double(from) + Double(current - from) * slide))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(NotchOnboardingStep.allCases.count)")
    }

    private func fill(_ step: NotchOnboardingStep) -> Color {
        guard step.rawValue < current else { return Theme.Notch.futureStep }
        return isDone(step) ? Theme.Notch.success : Theme.Notch.textTertiary
    }
}

/// A capsule action on the notch surface — the band's two rungs of the shared
/// button ladder (`UI/Components/ButtonStyles.swift`). `primary` is the same ember
/// pill the rest of the app uses for its one real action; `ghost` (an outlined
/// rung here, so its bounds read on black before hover) is the way past it.
///
/// The band's `.onDarkSurface()` is what makes the ladder pick `Theme.Notch`
/// tokens, so this looks right even with the app in light mode.
private struct NotchPillButton: View {
    enum Kind { case primary, ghost }

    let title: String
    var kind: Kind = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.sans(14, .semibold))
                // The band's buttons are a touch wider than the app's default.
                .padding(.horizontal, 2)
        }
        .modifier(NotchPillRung(kind: kind))
    }
}

/// Picks the rung. A `ViewBuilder` branch would give the two kinds different
/// view identities and lose the press state mid-interaction.
private struct NotchPillRung: ViewModifier {
    let kind: NotchPillButton.Kind

    func body(content: Content) -> some View {
        switch kind {
        case .primary: content.primaryButton()
        case .ghost: content.outlinedButton()
        }
    }
}

/// The small circular gear / close controls in the band's top row.
private struct NotchIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
        }
        .iconButton(size: 24, tooltip: label)
        .accessibilityLabel(label)
    }
}

/// The confirmation shown in place of the buttons once an ask is done: a check
/// ring that draws itself, then its glyph, then the badge's words. Its
/// VoiceOver label is its visible text.
private struct GrantedBadge: View {
    let text: String
    /// Trim of the ring and of the glyph, 0 to 1. 1 at rest.
    let ring: Double
    let glyph: Double

    private static let size: CGFloat = 16

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ZStack {
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                CheckGlyph()
                    .trim(from: 0, to: glyph)
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            .frame(width: Self.size, height: Self.size)
            Text(text)
                .font(Typography.sans(14, .semibold))
        }
        .foregroundStyle(Theme.Notch.success)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A check mark drawn as one stroke, so it can be trimmed on.
private struct CheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.36))
        return path
    }
}
