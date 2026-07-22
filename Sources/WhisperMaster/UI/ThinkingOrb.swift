import SwiftUI

// A faithful SwiftUI port of `thinking-orbs`
// (https://github.com/Jakubantalik/thinking-orbs, MIT © Jakub Antalik):
// dotted "thought-orb" loading indicators for AI/agent UIs. Six hand-tuned
// animated states, each drawn as a z-sorted field of matte grayscale dots —
// honestly 3D (rotated, depth-shaded, orthographically projected), depth carried
// by dot size + ink weight alone.
//
// The upstream renders on a 2D `<canvas>`; this port draws the identical marks
// on a SwiftUI `Canvas`, driven by `TimelineView(.animation)`. Both are plain
// filled circles — no filters, no Metal material — so it also rasterizes in the
// headless `ImageRenderer` snapshot path. Monochrome by design: on a dark
// substrate the ink is mirrored so near dots read bright.
//
// The engine (profiles, presets, mode painters) is ported 1:1 from `src/engine`
// so the tuning matches the published component; see `OrbView` for how the notch
// dictation surface consumes it.

// MARK: - Public surface

/// The six shipped states — each a distinct hand-tuned animation.
enum OrbState: String, CaseIterable, Sendable {
    case working    // particles on tilted orbits
    case searching  // a scan meridian sweeps a dotted globe
    case solving    // bands scramble in quarter turns, then click back
    case listening  // a waveform rolls through latitude rings
    case composing  // an undulating multi-band sash
    case shaping    // a dotted outline morphs circle → triangle → square
}

/// Which of the two tuned density presets to draw. They are separate designs,
/// not a scale factor: `small` (inline-text scale) and `large` (chat-avatar
/// scale) each carry their own dot count, dot size and speed tuning.
enum OrbPreset: Int, Sendable {
    case small = 20
    case large = 64
}

/// A dotted thinking orb. Pure SwiftUI `Canvas`; theme-aware; honors Reduce
/// Motion (renders one static representative frame) and the headless snapshot
/// path (deterministic static frame).
struct ThinkingOrb: View {
    var state: OrbState = .working
    /// Rendered edge length in points.
    var renderSize: CGFloat = 64
    /// Which baked density/speed tuning to use.
    var preset: OrbPreset = .large
    /// `true` → light ink for dark backgrounds; `false` → dark ink for light.
    var dark: Bool = true
    /// Multiplier on top of the preset's baked speed.
    var speed: Double = 1
    /// Freeze on a representative frame.
    var paused: Bool = false
    /// Extra mode options merged verbatim after preset resolution (e.g. the
    /// notch passes `["gain": …]` to make the listening wave react to the mic).
    var extraOpts: ModeOpts = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    private var resolved: OrbEngine.Resolved {
        OrbEngine.resolvePreset(state: state, preset: preset, extra: extraOpts)
    }

    var body: some View {
        let r = resolved
        let effSpeed = r.speed * speed
        Group {
            if reduceMotion || isSnapshot || paused {
                // One static, deterministic frame (matches the upstream reduced
                // path, which paints `t = 0.6`).
                Canvas { ctx, size in
                    OrbEngine.draw(r.mode, ctx, Double(min(size.width, size.height)), 0.6, dark, r.opts)
                }
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate * effSpeed
                    Canvas { ctx, size in
                        OrbEngine.draw(r.mode, ctx, Double(min(size.width, size.height)), t, dark, r.opts)
                    }
                }
            }
        }
        .frame(width: renderSize, height: renderSize)
        .accessibilityElement()
        .accessibilityLabel(Self.labels[state] ?? "")
    }

    private static let labels: [OrbState: String] = [
        .working: "Working", .searching: "Searching", .solving: "Solving",
        .listening: "Listening", .composing: "Composing", .shaping: "Shaping",
    ]
}

// MARK: - Engine

/// Per-mode draw option bag (mirrors the upstream `ModeOpts` object).
typealias ModeOpts = [String: Double]

private extension Dictionary where Key == String, Value == Double {
    func d(_ key: String, _ fallback: Double) -> Double { self[key] ?? fallback }
}

/// The ported rendering engine: shared 3D primitives, density profiles, the
/// preset resolver, and the six frame painters. Namespaced so the file reads as
/// one self-contained port.
enum OrbEngine {

    // MARK: Shared primitives (core.ts)

    struct Dot {
        var x: Double
        var y: Double
        var z: Double
        var r: Double
        /// Ink value: 0 = darkest ink. Mirrored on dark themes.
        var white: Double
        var a: Double = 1
    }

    typealias Projector = (Double, Double, Double) -> (Double, Double, Double)

    /// Deterministic hash in [0, 1).
    static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - floor(h)
    }

    /// Stable directions on a unit sphere (Fibonacci lattice).
    static func fibDir(_ i: Int, _ n: Int) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - (5.0).squareRoot())
        let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
        let rad = (1 - y * y).squareRoot()
        let a = Double(i) * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    /// Shortest signed angular distance, wrapped to (-π, π].
    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    /// Shared spin + tilt + orthographic projection.
    static func makeProj(_ yaw: Double, _ tilt: Double, _ cx: Double, _ cy: Double, _ scale: Double) -> Projector {
        let st = sin(tilt), ct = cos(tilt)
        let sy = sin(yaw), cyw = cos(yaw)
        return { x, y, z in
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    /// Painter: z-sort far→near, matte grayscale dots. On dark substrates the
    /// ink value is mirrored so near dots read bright.
    static func paint(_ ctx: GraphicsContext, _ dots: [Dot], _ dark: Bool, _ rMin: Double) {
        let sorted = dots.sorted { $0.z < $1.z }
        for d in sorted {
            let alpha = d.a
            if alpha < 0.02 { continue }
            let w = min(1, max(0, d.white))
            let g = dark ? 1 - w : w
            let r = max(rMin, d.r)
            let rect = CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(white: g, opacity: alpha)))
        }
    }

    /// Dot radii were tuned for a 300pt frame; sub-linear scaling keeps small
    /// spinners legible.
    static func radiusScale(_ size: Double, _ pow: Double) -> Double {
        Foundation.pow(size / 300, pow)
    }

    // MARK: Profiles + presets (profiles.ts, presets.ts)

    enum Mode: String { case orbits, globe, rubik, wave, ribbon, morph }

    struct Resolved { let mode: Mode; let speed: Double; let opts: ModeOpts }

    private static let stateToMode: [OrbState: Mode] = [
        .working: .orbits, .searching: .globe, .solving: .rubik,
        .listening: .wave, .composing: .ribbon, .shaping: .morph,
    ]

    private static let baseProfiles: [Mode: ModeOpts] = [
        .globe: ["latRings": 17, "lonDensity": 44, "rBase": 0.6, "rDepth": 1.7, "rBoost": 1.0,
                 "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3],
        .orbits: ["orbitN": 12, "ghostN": 40, "ghostR": 0.9, "ghostA": 0.5, "particles": 3,
                  "partR": 1.2, "partRDepth": 1.6, "rsPow": 0.6, "rMin": 0.3],
        .rubik: ["latRings": 15, "lonDensity": 40, "moveCount": 14, "rBase": 0.6, "rDepth": 1.7,
                 "rActive": 0.3, "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3],
        .wave: ["rings": 15, "lonDensity": 40, "rBase": 0.6, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3],
        .ribbon: ["lanes": 5, "segs": 88, "ghostN": 150, "rBase": 1.1, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3],
        .morph: ["rDot": 0.021, "iconD": 1, "rMin": 0.25],
    ]

    private struct Preset { let speed: Double; let count: Double; let size: Double; let extra: ModeOpts }

    // [mode][presetRawValue] → tuning
    private static let presets: [Mode: [Int: Preset]] = [
        .orbits: [
            64: Preset(speed: 1.885, count: 1, size: 1, extra: [:]),
            20: Preset(speed: 3.9, count: 0.238, size: 2.4, extra: [:]),
        ],
        .globe: [
            64: Preset(speed: 2.015, count: 0.42, size: 1.15, extra: ["scanMul": 4.08, "dimBase": 0.45]),
            20: Preset(speed: 2.665, count: 0.105, size: 1.75, extra: ["scanMul": 4.335, "dimBase": 0.45]),
        ],
        .rubik: [
            64: Preset(speed: 1.82, count: 0.35, size: 1.05, extra: [:]),
            20: Preset(speed: 1.95, count: 0.088, size: 1.9, extra: [:]),
        ],
        .wave: [
            64: Preset(speed: 4.388, count: 0.341, size: 1, extra: [:]),
            20: Preset(speed: 3.998, count: 0.105, size: 1.6, extra: [:]),
        ],
        .ribbon: [
            64: Preset(speed: 2.34, count: 0.25, size: 0.85, extra: ["spin": 0, "bandMul": 3.9, "wobMul": 1]),
            20: Preset(speed: 3.12, count: 0.051, size: 1.073, extra: ["spin": 0, "bandMul": 4.94, "wobMul": 1]),
        ],
        .morph: [
            64: Preset(speed: 2.405, count: 0.54, size: 0.395, extra: ["spread": 1.45]),
            20: Preset(speed: 2.08, count: 0.53, size: 1.011, extra: ["spread": 1.45]),
        ],
    ]

    private static let countPairs: [(String, String)] = [
        ("latRings", "lonDensity"), ("rings", "lonDensity"), ("lanes", "segs"),
    ]
    private static let countKeys = ["orbitN", "ghostN"]
    private static let iconDensityKeys = ["iconD"]
    private static let radiusKeys = ["rBase", "rDepth", "rActive", "rDot", "ghostR", "partR", "partRDepth"]

    private static func scaleCounts(_ opts: ModeOpts, _ scale: Double) -> ModeOpts {
        var out = opts
        var done = Set<String>()
        let rt = scale.squareRoot()
        for (a, b) in countPairs {
            if let va = out[a], let vb = out[b], !done.contains(a), !done.contains(b) {
                out[a] = max(2, (va * rt).rounded())
                out[b] = max(2, (vb * rt).rounded())
                done.insert(a); done.insert(b)
            }
        }
        for k in countKeys where !done.contains(k) {
            if let v = out[k] { out[k] = max(1, (v * scale).rounded()) }
        }
        for k in iconDensityKeys {
            if let v = out[k] { out[k] = max(0.02, v * scale) }
        }
        return out
    }

    private static func scaleRadii(_ opts: ModeOpts, _ scale: Double) -> ModeOpts {
        var out = opts
        for k in radiusKeys {
            if let v = out[k] { out[k] = v * scale }
        }
        out["rSizeMul"] = (out["rSizeMul"] ?? 1) * scale
        return out
    }

    static func resolvePreset(state: OrbState, preset: OrbPreset, extra: ModeOpts) -> Resolved {
        let mode = stateToMode[state] ?? .orbits
        let p = presets[mode]?[preset.rawValue] ?? Preset(speed: 1, count: 1, size: 1, extra: [:])
        var opts = baseProfiles[mode] ?? [:]
        if p.count != 1 { opts = scaleCounts(opts, p.count) }
        if p.size != 1 { opts = scaleRadii(opts, p.size) }
        opts.merge(p.extra) { _, new in new }
        opts.merge(extra) { _, new in new }
        return Resolved(mode: mode, speed: p.speed, opts: opts)
    }

    // MARK: Dispatch

    static func draw(_ mode: Mode, _ ctx: GraphicsContext, _ size: Double, _ t: Double, _ dark: Bool, _ o: ModeOpts) {
        switch mode {
        case .orbits: drawOrbits(ctx, size, t, dark, o)
        case .globe: drawGlobe(ctx, size, t, dark, o)
        case .rubik: drawRubik(ctx, size, t, dark, o)
        case .wave: drawWave(ctx, size, t, dark, o)
        case .ribbon: drawRibbon(ctx, size, t, dark, o)
        case .morph: drawMorph(ctx, size, t, dark, o)
        }
    }

    // MARK: Orbits — working (orbits.ts)

    static func drawOrbits(_ ctx: GraphicsContext, _ size: Double, _ t: Double, _ dark: Bool, _ o: ModeOpts) {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.82
        let pt = makeProj(t * 0.12, 0.3, cx, cy, 1)
        let rs = radiusScale(size, o.d("rsPow", 0.6))

        var dots: [Dot] = []
        let orbitN = Int(o.d("orbitN", 12))
        let ghostN = Int(o.d("ghostN", 40))
        let particles = Int(o.d("particles", 3))

        for orb in 0..<max(0, orbitN) {
            let h1 = hashD(Double(orb), 1.7)
            let h2 = hashD(Double(orb), 5.2)
            let h3 = hashD(Double(orb), 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(th)
            let ny = cos(phi)
            let nz = sin(phi) * sin(th)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let ul = max(1e-6, (ux * ux + uy * uy).squareRoot())
            ux /= ul; uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            for k in 0..<max(0, ghostN) {
                let a = (Double(k) / Double(ghostN)) * 2 * .pi
                let (px, py, z) = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z, r: o.d("ghostR", 0.9) * rs,
                                white: 0.72, a: o.d("ghostA", 0.5) * (0.4 + 0.6 * depth)))
            }
            for m in 0..<max(0, particles) {
                let a = t * speed + (Double(m) / Double(particles)) * 2 * .pi + h2 * 6
                let (px, py, z) = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z,
                                r: (o.d("partR", 1.2) + o.d("partRDepth", 1.6) * depth) * rs,
                                white: 0.3 - 0.22 * depth))
            }
        }
        paint(ctx, dots, dark, o.d("rMin", 0.3))
    }

    // MARK: Globe — searching (lattice.ts)

    static func drawGlobe(_ ctx: GraphicsContext, _ size: Double, _ t: Double, _ dark: Bool, _ o: ModeOpts) {
        let spin = 0.5
        let cx = size / 2, cy = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let pt = makeProj(t * spin, tilt, cx, cy, radius)
        let scan = t * (spin + (1.7 - spin) * o.d("scanMul", 1))
        let rs = radiusScale(size, o.d("rsPow", 0.6))
        let dimBase = o.d("dimBase", 1)

        var dots: [Dot] = []
        let latRings = Int(o.d("latRings", 17))
        let lonDensity = o.d("lonDensity", 44)
        for li in 0...max(1, latRings) {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (px, py, z) = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (z + 1) / 2
                let dd = angleDelta(lon + t * spin, scan)
                let boost = exp(-(dd * dd) / 0.18) * max(0, z)
                dots.append(Dot(x: px, y: py, z: z,
                                r: (o.d("rBase", 0.6) + o.d("rDepth", 1.7) * depth + o.d("rBoost", 1) * boost) * rs,
                                white: o.d("inkFar", 0.62) - o.d("inkSpan", 0.54) * depth,
                                a: dimBase + (1 - dimBase) * min(1, boost)))
            }
        }
        paint(ctx, dots, dark, o.d("rMin", 0.3))
    }

    // MARK: Rubik — solving (lattice.ts)

    private struct Move { let axis: Int; let lo: Double; let hi: Double; let ang: Double }

    private static func makeMoves(_ count: Int) -> [Move] {
        var moves: [Move] = []
        for i in 0..<count {
            let axis = min(2, Int(hashD(Double(i), 2.3) * 3))
            let lo = -1.0 + 0.5 * Double(min(3, Int(hashD(Double(i), 5.9) * 4)))
            let dir: Double = hashD(Double(i), 7.7) < 0.5 ? 1 : -1
            moves.append(Move(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * .pi / 2))
        }
        return moves
    }

    private static func solveCycle(_ time: Double, _ count: Int, _ slotDur: Double, _ rest: Double)
        -> (amount: [Double], active: Int) {
        let cyc = 2 * Double(count) * slotDur + rest
        let tc = time.truncatingRemainder(dividingBy: cyc)
        var amount = [Double](repeating: 0, count: count)
        var active = -1
        if tc < 2 * Double(count) * slotDur {
            let slot = Int(tc / slotDur)
            let p = (tc - Double(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - Foundation.pow(1 - cl, 3)
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                if u >= 0 && u < count { amount[u] = 1 - ep }
                active = u
            }
        }
        return (amount, active)
    }

    private static func applyMoves(_ p: (Double, Double, Double), _ moves: [Move],
                                   _ sc: (amount: [Double], active: Int)) -> (Double, Double, Double, Bool) {
        var (x, y, z) = p
        var inActive = false
        for i in 0..<moves.count {
            if sc.amount[i] <= 0 { continue }
            let mv = moves[i]
            let coord = mv.axis == 0 ? x : (mv.axis == 1 ? y : z)
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == sc.active { inActive = true }
            let a = mv.ang * sc.amount[i]
            let ca = cos(a), sa = sin(a)
            if mv.axis == 0 {
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            } else if mv.axis == 1 {
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            } else {
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return (x, y, z, inActive)
    }

    static func drawRubik(_ ctx: GraphicsContext, _ size: Double, _ t: Double, _ dark: Bool, _ o: ModeOpts) {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.82
        let pt = makeProj(t * 0.55, 0.35 + 0.1 * sin(t * 0.9), cx, cy, R)
        let rs = radiusScale(size, o.d("rsPow", 0.6))
        let moveCount = Int(o.d("moveCount", 14))
        let moves = makeMoves(moveCount)
        let sc = solveCycle(t, moveCount, 0.42, 1.2)

        var dots: [Dot] = []
        let latRings = Int(o.d("latRings", 15))
        let lonDensity = o.d("lonDensity", 40)
        for li in 0...max(1, latRings) {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (x, y, z, inActive) = applyMoves((cosLat * cos(lon), sinLat, cosLat * sin(lon)), moves, sc)
                let (px, py, zr) = pt(x, y, z)
                let depth = (zr + 1) / 2
                dots.append(Dot(x: px, y: py, z: zr,
                                r: (o.d("rBase", 0.6) + o.d("rDepth", 1.7) * depth + (inActive ? o.d("rActive", 0.3) : 0)) * rs,
                                white: o.d("inkFar", 0.62) - o.d("inkSpan", 0.54) * depth - (inActive ? 0.14 : 0)))
            }
        }
        paint(ctx, dots, dark, o.d("rMin", 0.3))
    }

    // MARK: Wave — listening (lattice.ts) + a `gain` knob for mic reactivity

    static func drawWave(_ ctx: GraphicsContext, _ size: Double, _ t: Double, _ dark: Bool, _ o: ModeOpts) {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.874
        let pt = makeProj(t * 0.18, 0.38, cx, cy, 1)
        let rs = radiusScale(size, o.d("rsPow", 0.6))
        // Not in the upstream engine: scales the undulation amplitude so a live
        // audio level can drive the wave without changing tempo (which would
        // jump the phase). Defaults to 1 → byte-identical to upstream.
        let gain = o.d("gain", 1)

        var dots: [Dot] = []
        let rings = Int(o.d("rings", 15))
        let lonDensity = o.d("lonDensity", 40)
        for ri in 0...max(1, rings) {
            let lat = -Double.pi / 2 + (Double(ri) / Double(rings)) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            let w = (0.62 * sin(t * 2.1 - Double(ri) * 0.52) + 0.38 * sin(t * 1.27 + Double(ri) * 0.83)) * gain
            let rr = R * (0.88 + 0.105 * w)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (px, py, z) = pt(cosLat * cos(lon) * rr, sinLat * rr, cosLat * sin(lon) * rr)
                let depth = (z / R + 1) / 2
                let crest = max(0, w)
                dots.append(Dot(x: px, y: py, z: z,
                                r: (o.d("rBase", 0.6) + o.d("rDepth", 1.7) * depth) * (1 + 0.4 * crest) * rs,
                                white: 0.66 - 0.56 * depth - 0.1 * crest))
            }
        }
        paint(ctx, dots, dark, o.d("rMin", 0.3))
    }

    // MARK: Ribbon — composing (ribbon.ts)

    static func drawRibbon(_ ctx: GraphicsContext, _ size: Double, _ t: Double, _ dark: Bool, _ o: ModeOpts) {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.78
        let spin = o.d("spin", 1)
        let pt = makeProj(t * 0.1 * spin, 0.3, cx, cy, 1)
        let rs = radiusScale(size, o.d("rsPow", 0.6))

        var dots: [Dot] = []
        let ghostN = Int(o.d("ghostN", 150))
        for i in 0..<max(0, ghostN) {
            let dir = fibDir(i, ghostN)
            let (px, py, z) = pt(dir.0 * R, dir.1 * R, dir.2 * R)
            let depth = (z / R + 1) / 2
            dots.append(Dot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
        }

        let ya = t * 0.24 * spin
        let ta = 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux = cos(ya), uy = 0.0, uz = sin(ya)
        let vx = -uz * sin(ta), vy = cos(ta), vz = ux * sin(ta)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx

        let baseLanes = o.d("lanes", 5)
        let segs = Int(o.d("segs", 88))
        let lanes = max(1, Int((baseLanes * o.d("bandMul", 1)).rounded()))
        for w in 0..<lanes {
            let laneOff = (Double(w) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(w) - Double(lanes - 1) / 2) / max(1, Double(lanes - 1) / 2)
            for k in 0..<max(0, segs) {
                let a = (Double(k) / Double(segs)) * 2 * .pi
                let wob = (0.16 * sin(a * 3 - t * 1.7 + Double(w) * 0.22) + 0.07 * sin(a * 5 + t * 1.1)) * o.d("wobMul", 1)
                let off = laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = (x * x + y * y + z * z).squareRoot()
                let (px, py, zr) = pt((x / l) * R, (y / l) * R, (z / l) * R)
                let depth = (zr / R + 1) / 2
                dots.append(Dot(x: px, y: py, z: zr,
                                r: (o.d("rBase", 1.1) + o.d("rDepth", 1.7) * depth) * (1 - 0.25 * edge) * rs,
                                white: 0.52 - 0.44 * depth + 0.18 * edge,
                                a: 0.4 + 0.6 * depth))
            }
        }
        paint(ctx, dots, dark, o.d("rMin", 0.3))
    }

    // MARK: Morph — shaping (morph.ts)

    private static func smoothE(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// Closed path parameterised by arc length (top-centre start, clockwise).
    private static func polyPath(_ verts: [(Double, Double)]) -> (Double) -> (Double, Double) {
        let V = verts.count
        var L = [Double](repeating: 0, count: V)
        var total = 0.0
        for i in 0..<V {
            let a = verts[i], b = verts[(i + 1) % V]
            let l = (b.0 - a.0).magnitude == 0 && (b.1 - a.1).magnitude == 0
                ? 0 : hypot(b.0 - a.0, b.1 - a.1)
            L[i] = l
            total += l
        }
        return { f in
            var target = f * total
            var i = 0
            while target > L[i] && i < V - 1 { target -= L[i]; i += 1 }
            let a = verts[i], b = verts[(i + 1) % V]
            let ff = L[i] != 0 ? min(1, target / L[i]) : 0
            return (a.0 + (b.0 - a.0) * ff, a.1 + (b.1 - a.1) * ff)
        }
    }

    private static let circlePath: (Double) -> (Double, Double) = { f in
        let a = -Double.pi / 2 + f * 2 * .pi
        return (cos(a) * 0.24, sin(a) * 0.24)
    }
    private static let trianglePath = polyPath([(0.0, -0.26), (0.24, 0.16), (-0.24, 0.16)])
    private static let squarePath = polyPath([(0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)])
    private static var cycle: [(Double) -> (Double, Double)] { [circlePath, trianglePath, squarePath] }

    private static func morphN(_ d: Double) -> Int { max(6, Int((34 * d).rounded())) }

    static func drawMorph(_ ctx: GraphicsContext, _ size: Double, _ t: Double, _ dark: Bool, _ o: ModeOpts) {
        let hold = 1.4, morph = 0.9
        let seg = hold + morph
        let cyc = cycle
        let K = cyc.count
        let tc = t.truncatingRemainder(dividingBy: seg * Double(K))
        let k = Int(tc / seg)
        let local = tc - Double(k) * seg
        let m = local > hold ? smoothE((local - hold) / morph) : 0
        let sprd = o.d("spread", 1)

        let pA = cyc[k], pB = cyc[(k + 1) % K]
        let M = 160
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(M)
        for i in 0..<M {
            let f = Double(i) / Double(M)
            let a = pA(f), b = pB(f)
            pts.append(((a.0 + (b.0 - a.0) * m) * sprd, (a.1 + (b.1 - a.1) * m) * sprd))
        }
        var L = [Double](repeating: 0, count: M)
        var total = 0.0
        for i in 0..<M {
            let a = pts[i], b = pts[(i + 1) % M]
            let l = hypot(b.0 - a.0, b.1 - a.1)
            L[i] = l
            total += l
        }

        let n = morphN(o.d("iconD", 1))
        let re = o.d("rDot", 0.021) * 1.35 * sprd
        let pulse = 1 + 0.02 * sin(local * 3.1)

        var dots: [Dot] = []
        let c2 = size / 2
        var segIdx = 0
        var acc = 0.0
        for k2 in 0..<n {
            let target = (Double(k2) / Double(n)) * total
            while acc + L[segIdx] < target && segIdx < M - 1 { acc += L[segIdx]; segIdx += 1 }
            let a = pts[segIdx], b = pts[(segIdx + 1) % M]
            let f = L[segIdx] != 0 ? min(1, (target - acc) / L[segIdx]) : 0
            let x = (a.0 + (b.0 - a.0) * f) * pulse
            let y = (a.1 + (b.1 - a.1) * f) * pulse
            dots.append(Dot(x: c2 + x * size, y: c2 + y * size, z: 0,
                            r: max(0.35, re * size), white: 0.1))
        }
        paint(ctx, dots, dark, o.d("rMin", 0.25))
    }
}
