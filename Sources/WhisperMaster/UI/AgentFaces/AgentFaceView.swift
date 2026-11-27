import SwiftUI

/// One agent's face: the dotted orb as the body, two eye dots, a brow over each,
/// one state ring and the badges. No mouth, no pupils, nothing that tracks the
/// pointer. What it shows is `AgentFaceLook`; this view only draws it.
///
/// Motion budget: the silhouette, the badges and a steady ring are drawn outside
/// any timeline. Only a hero face with a running figure gets
/// `TimelineView(.animation(minimumInterval: 1/30))`, and it drives the orb's
/// `time` itself, so the orb's own uncapped timeline never runs. Every other face
/// redraws only on the dates in `AgentFaceSchedulePlan` (a blink, a pulse, the
/// ring fade), and a face with no such date has no timeline at all.
struct AgentFaceView: View {
    let identity: AgentFaceIdentity
    let state: AgentFaceState
    var size: CGFloat = 36
    /// One of the at most two faces that animate (`AgentRail.heroes`).
    var hero: Bool = false
    /// Low Power, a hot Mac or VoiceOver (`OnboardingMotionPolicy`). System
    /// Reduce Motion is read from the environment as well.
    var reducedMotion: Bool = false
    var since: Date? = nil
    var contextClearedAt: Date? = nil
    /// Draw this instant and nothing else (the snapshot renderer).
    var now: Date? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isSnapshot) private var isSnapshot

    private var dark: Bool { colorScheme == .dark }
    private var still: Bool { reducedMotion || systemReduceMotion }
    private var look: AgentFaceLook { AgentFaceLook.look(for: state, reduceMotion: still) }
    private var fixedInstant: Date? { now ?? (isSnapshot ? Date() : nil) }

    /// The context clear runs the orb inside the timeline for its 0.6 s.
    private var clearing: Bool {
        guard !still, let c = contextClearedAt else { return false }
        let t = (fixedInstant ?? Date()).timeIntervalSince(c)
        return t >= 0 && t < AgentFaceMotion.clearDuration
    }

    private var heroMoving: Bool { hero && look.moving && !still && fixedInstant == nil }

    var body: some View {
        let look = look
        ZStack {
            AgentFaceShape(silhouette: identity.role.silhouette)
                .fill(Theme.AgentFace.identity(identity.hue, dark: dark).opacity(dark ? 0.18 : 0.13))
            AgentFaceShape(silhouette: identity.role.silhouette)
                .stroke(Theme.AgentFace.identity(identity.hue, dark: dark).opacity(0.45), lineWidth: 1)
            if !heroMoving && !clearing { orb(look, gather: look.gather, time: nil) }
            if !look.ringAnimates { ring(look, opacity: 1, pulse: 0) }
            live(look)
        }
        .grayscale(look.desaturated ? 1 : 0)
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) { roleBadge.offset(x: size * 0.16, y: size * 0.08) }
        .overlay(alignment: .topTrailing) { stateBadge(look).offset(x: size * 0.14, y: -size * 0.1) }
        .overlay(alignment: .topLeading) { harnessMark.offset(x: -size * 0.16, y: -size * 0.12) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.accessibilityLabel)
        .accessibilityValue(look.accessibilityValue)
    }

    // MARK: Moving layer

    @ViewBuilder
    private func live(_ look: AgentFaceLook) -> some View {
        if let instant = fixedInstant {
            features(look, at: instant)
        } else if heroMoving {
            TimelineView(.animation(minimumInterval: AgentFaceMotion.frameInterval, paused: !heroMoving)) { ctx in
                features(look, at: ctx.date)
            }
        } else {
            let plan = still ? AgentFaceSchedulePlan() : AgentFaceMotion.plan(
                look, blinkInterval: identity.blinkInterval, since: since,
                clearedAt: contextClearedAt, hero: hero)
            if plan.isEmpty {
                features(look, at: Date())
            } else {
                TimelineView(AgentFaceTimelineSchedule(plan: plan)) { ctx in
                    features(look, at: ctx.date)
                }
            }
        }
    }

    private func features(_ look: AgentFaceLook, at date: Date) -> some View {
        let frame = AgentFaceMotion.frame(
            look, blinkInterval: identity.blinkInterval, since: since,
            clearedAt: still ? nil : contextClearedAt, at: date)
        return ZStack {
            if heroMoving || clearing {
                orb(look, gather: frame.gather,
                    time: heroMoving ? date.timeIntervalSinceReferenceDate : nil)
            }
            if look.ringAnimates { ring(look, opacity: frame.ringOpacity, pulse: frame.pulse) }
            Canvas { ctx, canvasSize in
                AgentFaceFeatures.draw(
                    ctx, size: min(canvasSize.width, canvasSize.height), eyes: frame.eyes,
                    gaze: look.gaze, brows: look.brows,
                    ink: Theme.AgentFace.ink(dark: dark), halo: Theme.AgentFace.railFill(dark: dark))
            }
        }
    }

    // MARK: Parts

    private func orb(_ look: AgentFaceLook, gather: Double, time: Double?) -> some View {
        ThinkingOrb(
            state: look.orb, renderSize: size * 0.82, preset: .small, dark: dark,
            paused: time == nil, extraOpts: look.orbGain.map { ["gain": $0] } ?? [:],
            time: time, gather: gather)
            .opacity(0.62 * look.dotOpacity)
            .accessibilityHidden(true)
    }

    private func ringColor(_ ring: AgentFaceLook.Ring) -> Color {
        switch ring {
        case .none: return .clear
        case .identity: return Theme.AgentFace.identity(identity.hue, dark: dark)
        case .waiting: return Theme.AgentFace.waiting(dark: dark)
        case .done: return Theme.AgentFace.done(dark: dark)
        case .error: return Theme.AgentFace.error(dark: dark)
        case .budget: return Theme.AgentFace.budget(dark: dark)
        }
    }

    @ViewBuilder
    private func ring(_ look: AgentFaceLook, opacity: Double, pulse: Double) -> some View {
        if look.ring != .none, opacity > 0 {
            let color = ringColor(look.ring)
            let width = max(2, size * 0.06)
            ZStack {
                if pulse > 0 {
                    AgentFaceShape(silhouette: identity.role.silhouette)
                        .stroke(color.opacity(0.22 * pulse), lineWidth: width + 3 * pulse)
                        .padding(-2 * pulse)
                }
                AgentFaceShape(silhouette: identity.role.silhouette)
                    .stroke(color, lineWidth: width)
            }
            .opacity(opacity)
        }
    }

    private var roleBadge: some View {
        Text(identity.badge)
            .font(Typography.sans(11, .bold))
            .foregroundStyle(Theme.AgentFace.badgeInk(dark: dark))
            .padding(.horizontal, 3)
            .frame(minWidth: 16, minHeight: 14)
            .background(Capsule().fill(Theme.AgentFace.badgeFill(identity.hue, dark: dark)))
            .overlay(Capsule().stroke(Theme.AgentFace.railFill(dark: dark), lineWidth: 1.5))
            .fixedSize()
    }

    @ViewBuilder
    private func stateBadge(_ look: AgentFaceLook) -> some View {
        if let text = look.badge.text {
            Text(text)
                .font(Typography.sans(11, .heavy))
                .foregroundStyle(Theme.AgentFace.badgeInk(dark: dark))
                .frame(width: 15, height: 15)
                .background(Circle().fill(ringColor(look.ring)))
                .overlay(Circle().stroke(Theme.AgentFace.railFill(dark: dark), lineWidth: 1.5))
                .fixedSize()
        }
    }

    @ViewBuilder
    private var harnessMark: some View {
        if let harness = identity.harness {
            Text(harness.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.AgentFace.secondaryInk(dark: dark))
                .fixedSize()
        }
    }
}

/// The face's silhouette: identity, never state.
struct AgentFaceShape: Shape {
    let silhouette: AgentFaceSilhouette

    func path(in rect: CGRect) -> Path {
        switch silhouette {
        case .circle:
            return Path(ellipseIn: rect)
        case .roundedSquare:
            return Path(roundedRect: rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04),
                        cornerRadius: rect.width * 0.26, style: .continuous)
        case .hexagon:
            // Flat top and bottom, so the brows sit under a straight edge.
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) / 2
            let verts = (0..<6).map { i -> CGPoint in
                let a = Double(i) * .pi / 3
                return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
            return Self.rounded(verts, radius: r * 0.22)
        }
    }

    private static func rounded(_ v: [CGPoint], radius: CGFloat) -> Path {
        func toward(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
            let len = hypot(b.x - a.x, b.y - a.y)
            return CGPoint(x: a.x + (b.x - a.x) * d / len, y: a.y + (b.y - a.y) * d / len)
        }
        var p = Path()
        let n = v.count
        for i in 0..<n {
            let prev = v[(i + n - 1) % n], cur = v[i], next = v[(i + 1) % n]
            let a = toward(cur, prev, radius), b = toward(cur, next, radius)
            if i == 0 { p.move(to: a) } else { p.addLine(to: a) }
            p.addQuadCurve(to: b, control: cur)
        }
        p.closeSubpath()
        return p
    }
}

/// Eyes and brows: dots, arcs and short lines only.
enum AgentFaceFeatures {
    static func draw(
        _ ctx: GraphicsContext, size s: CGFloat, eyes: AgentFaceLook.Eyes,
        gaze: AgentFaceLook.Gaze, brows: AgentFaceLook.Brows, ink: Color, halo: Color
    ) {
        let (gx, gy): (CGFloat, CGFloat) = {
            switch gaze {
            case .center: return (0, 0)
            case .upLeft: return (-0.04 * s, -0.04 * s)
            case .side: return (0.05 * s, 0)
            case .down: return (0, 0.045 * s)
            // The rail is at the right edge, so the screen centre is to the left.
            case .towardScreenCentre: return (-0.05 * s, -0.01 * s)
            }
        }()
        let eyeY = 0.5 * s + gy
        let dx = 0.15 * s
        let r = 0.068 * s
        let strokeW = max(1.3, 0.05 * s)

        for side in [-1.0, 1.0] as [CGFloat] {
            let c = CGPoint(x: 0.5 * s + side * dx + gx, y: eyeY)
            switch eyes {
            case .open, .wide:
                let rr = eyes == .wide ? r * 1.3 : r
                fill(ctx, Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), ink, halo)
            case .flat:
                fill(ctx, Path(roundedRect: CGRect(x: c.x - 1.3 * r, y: c.y - 0.45 * r, width: 2.6 * r, height: 0.9 * r),
                               cornerRadius: 0.45 * r), ink, halo)
            case .halfClosed:
                var p = Path()
                p.move(to: CGPoint(x: c.x - 1.1 * r, y: c.y))
                p.addArc(center: c, radius: 1.1 * r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                p.closeSubpath()
                fill(ctx, p, ink, halo)
            case .closed:
                var p = Path()
                p.move(to: CGPoint(x: c.x - 1.25 * r, y: c.y + 0.2 * r))
                p.addLine(to: CGPoint(x: c.x + 1.25 * r, y: c.y + 0.2 * r))
                stroke(ctx, p, ink, halo, strokeW)
            case .happyArcs:
                var p = Path()
                p.addArc(center: CGPoint(x: c.x, y: c.y + 0.6 * r), radius: 1.25 * r,
                         startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
                stroke(ctx, p, ink, halo, strokeW)
            }

            // Brows: the inner end is the one toward the face's centre.
            let lift: CGFloat
            let tilt: CGFloat
            switch brows {
            case .level: (lift, tilt) = (0, 0)
            case .raised: (lift, tilt) = (0.045 * s, 0)
            case .worried: (lift, tilt) = (0.02 * s, 0.03 * s)
            // A mild slant: "needs you", not anger.
            case .slanted: (lift, tilt) = (0.005 * s, -0.022 * s)
            case .low: (lift, tilt) = (-0.02 * s, 0)
            }
            let browY = 0.5 * s - 0.19 * s + gy * 0.5 - lift
            let half = 0.058 * s
            let bx = c.x - gx * 0.4
            let inner = CGPoint(x: bx - side * half, y: browY - tilt)
            let outer = CGPoint(x: bx + side * half, y: browY + tilt * 0.4)
            // A slight upward arch reads friendlier than a straight bar.
            let arch = CGPoint(x: (inner.x + outer.x) / 2, y: (inner.y + outer.y) / 2 - 0.03 * s)
            var b = Path()
            b.move(to: outer)
            b.addQuadCurve(to: inner, control: arch)
            stroke(ctx, b, ink, halo, strokeW * 0.9)
        }
    }

    private static func fill(_ ctx: GraphicsContext, _ p: Path, _ ink: Color, _ halo: Color) {
        ctx.stroke(p, with: .color(halo.opacity(0.9)), lineWidth: 2)
        ctx.fill(p, with: .color(ink))
    }

    private static func stroke(_ ctx: GraphicsContext, _ p: Path, _ ink: Color, _ halo: Color, _ w: CGFloat) {
        let round = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
        ctx.stroke(p, with: .color(halo.opacity(0.9)), style: StrokeStyle(lineWidth: w + 2, lineCap: .round))
        ctx.stroke(p, with: .color(ink), style: round)
    }
}

/// Wraps `AgentFaceSchedulePlan` for `TimelineView`. The iterator ends when the
/// plan has no next date, so a finished pulse or fade stops redrawing.
struct AgentFaceTimelineSchedule: TimelineSchedule {
    let plan: AgentFaceSchedulePlan

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var cursor: Date? = startDate
        var first = true
        return AnyIterator {
            guard let current = cursor else { return nil }
            if first { first = false; return current }
            cursor = plan.next(after: current)
            return cursor
        }
    }
}
