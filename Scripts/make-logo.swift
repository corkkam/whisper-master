#!/usr/bin/env swift
//
//  make-logo.swift — regenerates the Whisper Master brand mark.
//
//  The mark IS the orb: the same dotted, honestly-3D sphere the notch draws
//  while it is listening to you (`OrbView` → `ThinkingOrb`, the `wave` figure),
//  frozen on one frame and inked in the brand's ember ramp. The thing people
//  watch while they dictate is the thing on the Dock icon.
//
//  Run:  swift Scripts/make-logo.swift
//
//  Writes, from the repo root:
//    Sources/WhisperMaster/Resources/WhisperMasterLogo.png   (1024, the tile)
//    Sources/WhisperMaster/Resources/WhisperMasterTrayGlyph.png (template glyph)
//    Resources/AppIcon.icns                                  (full iconset)
//
//  ⚠️ The wave painter below is a deliberate *frozen copy* of the one in
//  `UI/ThinkingOrb.swift`, not a shared import. A logo must not change shape
//  because somebody retuned an animation, and this script has no SwiftUI
//  context to render a `Canvas` in. If you re-tune the engine and want the mark
//  to follow, port the change here on purpose and re-run.
//
//  ⚠️ A dot field cannot be downscaled. Rendering the 1024 tile and resampling
//  it to 16pt turns ~450 dots into grey mush, so every icon size is drawn at
//  its own density (`Density.forPixels`) — fewer, larger dots as the box
//  shrinks, the same way the orb itself ships two hand-tuned presets rather
//  than one scaled design.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - The wave figure (frozen copy of OrbEngine.drawWave)

struct Dot {
    var x: Double, y: Double, z: Double
    var r: Double
    var depth: Double
}

private func makeProj(_ yaw: Double, _ tilt: Double, _ cx: Double, _ cy: Double)
    -> (Double, Double, Double) -> (Double, Double, Double) {
    let st = sin(tilt), ct = cos(tilt)
    let sy = sin(yaw), cyw = cos(yaw)
    return { x, y, z in
        let x1 = x * cyw + z * sy
        let z1 = -x * sy + z * cyw
        let y1 = y * ct - z1 * st
        let z2 = y * st + z1 * ct
        return (cx + x1, cy - y1, z2)
    }
}

/// Latitude rings on a sphere whose radius undulates — the `listening` orb.
/// `gain` is damped well below the animation's, so the mark keeps a clean
/// spherical silhouette: at full gain the wave deforms the outline into a pear,
/// which is fine for two frames of motion and wrong for something stamped on a
/// Dock icon forever.
func waveDots(box: Double, density: Density, t: Double, gain: Double,
              tilt: Double, yaw: Double) -> [Dot] {
    let c = box / 2
    let R = c * 0.874
    let project = makeProj(yaw, tilt, c, c)
    // The engine's own sub-linear radius scaling, so a small box keeps legible
    // dots instead of specks.
    let radiusScale = pow(box / 300, 0.6) * density.dotScale

    var dots: [Dot] = []
    for ring in 0...density.rings {
        let lat = -Double.pi / 2 + (Double(ring) / Double(density.rings)) * .pi
        let cosLat = cos(lat), sinLat = sin(lat)
        let w = (0.62 * sin(t * 2.1 - Double(ring) * 0.52)
                 + 0.38 * sin(t * 1.27 + Double(ring) * 0.83)) * gain
        let rr = R * (0.88 + 0.105 * w)
        let count = max(1, Int((abs(cosLat) * density.lonDensity).rounded()))
        for i in 0..<count {
            let lon = (Double(i) / Double(count)) * 2 * .pi
            let (px, py, z) = project(cosLat * cos(lon) * rr, sinLat * rr, cosLat * sin(lon) * rr)
            let depth = (z / R + 1) / 2
            let crest = max(0, w)
            dots.append(Dot(x: px, y: py, z: z,
                            r: (0.6 + 1.7 * depth) * (1 + 0.4 * crest) * radiusScale,
                            depth: depth))
        }
    }
    return dots
}

// MARK: - Per-size tuning

/// How many dots, and how big, for a given rendered box. Hand-stepped rather
/// than interpolated — these are the sizes macOS actually asks for.
struct Density {
    var rings: Int
    var lonDensity: Double
    var dotScale: Double
    /// The orb's share of the **tile** (not the canvas). It grows as the box
    /// shrinks: at 16pt there is no detail left to protect and the margin is
    /// the only thing competing with the mark, so the orb takes more of it.
    var orbShare: Double

    /// Dot sizes carry a ~1.24 boost over the first tuning: at the original
    /// scale the field was legible on a 1024 tile and thin everywhere the mark
    /// is actually seen. Bolder dots is the single biggest clarity win at small
    /// sizes, ahead of any colour change.
    static func forPixels(_ px: Int) -> Density {
        switch px {
        case ...36:  return Density(rings: 6,  lonDensity: 15, dotScale: 2.36, orbShare: 0.99)
        case ...72:  return Density(rings: 8,  lonDensity: 22, dotScale: 2.11, orbShare: 0.97)
        case ...160: return Density(rings: 11, lonDensity: 32, dotScale: 2.29, orbShare: 0.91)
        default:     return Density(rings: 14, lonDensity: 40, dotScale: 2.11, orbShare: 0.89)
        }
    }

    /// Below this the dot field stops being a sphere and becomes noise: there
    /// are fewer pixels across the orb than it has latitude rings, so every
    /// ring lands on the same row and the mark reads as three brown bars. The
    /// 16pt slot gets `drawSolidOrb` instead — the same lit ball the dots
    /// describe, drawn directly. Progressive simplification, not a different
    /// logo.
    static let stippleFloor = 20

    /// The menu bar's own tuning, not a tier off the ladder above. A tray glyph
    /// is one flat ink on a busy strip, so it wants fewer and much bolder dots
    /// than a colour tile of the same size, which can lean on hue and glow.
    static let tray = Density(rings: 6, lonDensity: 14, dotScale: 3.2, orbShare: 0.98)

    /// The landing page's nav/footer mark, also its own tuning rather than a
    /// tier. At 24px the size-derived tier put ~60 dots in the box, which at
    /// true size reads as scatter rather than as a sphere — a small mark wants
    /// fewer and bolder, the same trade the tray makes. `orbShare` is pulled in
    /// so the outer ring isn't grazing the tile's rounded corners.
    static let wordmark = Density(rings: 5, lonDensity: 12, dotScale: 2.9, orbShare: 0.88)
}

/// The one frame of the animation the mark is cut from, and the geometry around
/// it. `t` is the same representative instant the orb freezes on under Reduce
/// Motion, so a user who never sees it move still sees the icon's pose.
enum Mark {
    static let time = 0.6
    static let gain = 0.24
    static let tilt = 0.38
    static let yaw = 0.55
    /// Apple's icon grid: the tile is 824 of a 1024 canvas.
    static let tileInset = 100.0 / 1024.0
    /// The tile's share of the canvas, which is what `Density.orbShare` is
    /// measured against — an orb sized off the *canvas* is wider than the
    /// squircle and gets its outer rings clipped by the tile's own edge.
    static var tileShare: Double { 1 - 2 * tileInset }
}

/// Who owns the tile's outline.
///
/// This is not decoration — get it wrong and the mark is either clipped or
/// floating in dead space inside its own slot.
enum TileShape {
    /// Apple's icon grid: an 824/1024 squircle with a transparent margin. The
    /// margin is what makes the icon sit correctly beside stock Dock icons.
    case iconGrid
    /// Fills its box as a plain square, because the **host** clips the corner —
    /// `BrandLogo`'s `RoundedRectangle`, or iOS, which rounds the Apple touch
    /// icon itself and expects a full square to round.
    case hostClipped
    /// Fills its box and bakes its own squircle, for hosts that clip nothing and
    /// show the file as-is — the favicon.
    case rounded
}

// MARK: - Palette (Theme.swift)

struct RGB { var r, g, b: Double }
func hex(_ v: UInt32) -> RGB {
    RGB(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255, b: Double(v & 0xff) / 255)
}
func mix(_ a: RGB, _ b: RGB, _ f: Double) -> RGB {
    RGB(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f, b: a.b + (b.b - a.b) * f)
}
func cg(_ c: RGB, _ alpha: Double) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: alpha)
}

let ember = hex(0xff6a3d)        // Theme.Ember.base
let emberBright = hex(0xff8b64)  // Theme.Ember.bright
/// The sphere's far side. Deeper than `Ember.ink`, but **not** near-black: at
/// `0x5c1f0a` the far hemisphere sank into the ground and the mark read as a
/// smudge in a dark tile rather than a lit ball.
let emberShadow = hex(0x95401c)
let warmWhite = hex(0xfff2ea)
let groundTop = hex(0x0e1016)
let groundBottom = hex(0x07090e) // the ground the mark it replaces already used

/// Ink for a dot at `depth` (0 = far side of the sphere, 1 = nearest).
///
/// One hue, dark to light. A cool far hemisphere (signal teal, to spend both
/// brand accents in one mark) was drawn and rejected: a saturated hue at low
/// alpha over near-black reads as grey dirt rather than distance — the same
/// finding that keeps `NotchGlow`'s strengths low and its ember out of the
/// machine states.
/// The alpha floor is the difference between "a lit sphere" and "a smudge". At
/// 0.16 the far hemisphere was effectively absent, so the mark lost its
/// silhouette and read as a few bright dots floating in a dark tile — most
/// visibly at the 34/58pt sizes `BrandLogo` asks for. It is deliberately short
/// of the ceiling: push it past ~0.5 and every dot carries the same weight,
/// which flattens the sphere into a disc.
let inkFloor = 0.46

func ink(depth: Double) -> (RGB, Double) {
    let f = min(1, max(0, depth))
    let colour: RGB = f < 0.5
        ? mix(emberShadow, ember, f / 0.5)
        : mix(ember, mix(emberBright, warmWhite, (f - 0.5) / 0.5), (f - 0.5) / 0.5)
    return (colour, inkFloor + (1 - inkFloor) * pow(f, 0.9))
}

// MARK: - Drawing

func newContext(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// A superellipse, which is what a macOS tile actually is — a plain rounded
/// rect with circular corners reads visibly tighter beside stock icons.
func squircle(_ rect: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let steps = 720
    for i in 0...steps {
        let th = Double(i) / Double(steps) * 2 * .pi
        let c = cos(th), s = sin(th)
        let x = a * pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = b * pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = CGPoint(x: rect.midX + CGFloat(x), y: rect.midY + CGFloat(y))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// The full-colour tile: ground, ember bloom, orb.
///
/// `displayUnits` is the size the tile will actually be **seen** at, which is
/// what the dot field is laid out for; `pixels` is only the resolution it is
/// written at. They differ for the in-app assets, which are shown at 34/58pt
/// but stored at 4× for Retina. Passing `nil` means "seen at its own size",
/// which is every iconset slot.
///
/// ⚠️ This distinction is the whole reason the mark stopped being a smudge.
/// `BrandLogo` used to load the 1024 tile and `.resizable()` it down to 34pt —
/// ~450 dots into 34 points, which is the exact failure the file header warns
/// about, reached through SwiftUI instead of through a resample.
///
/// `shape` decides who owns the tile's outline — see `TileShape`.
func renderTile(pixels: Int, displayUnits: Int? = nil, shape: TileShape = .iconGrid,
                density: Density? = nil) -> CGImage {
    let S = Double(displayUnits ?? pixels)
    let ctx = newContext(pixels)
    ctx.scaleBy(x: CGFloat(Double(pixels) / S), y: CGFloat(Double(pixels) / S))
    let inset = shape == .iconGrid ? S * Mark.tileInset : 0
    let tile = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    ctx.saveGState()
    // Always clip: the ground has to stop exactly at the outline, whether that
    // outline is ours or the host's.
    ctx.addPath(shape == .hostClipped ? CGPath(rect: tile, transform: nil) : squircle(tile))
    ctx.clip()

    ctx.drawLinearGradient(
        CGGradient(colorsSpace: space,
                   colors: [cg(groundTop, 1), cg(groundBottom, 1)] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

    // Ember rising off the bottom edge — inherited from the mark this replaces,
    // so the tile reads as the same family rather than a stranger.
    ctx.drawRadialGradient(
        CGGradient(colorsSpace: space,
                   colors: [cg(ember, 0.26), cg(ember, 0)] as CFArray,
                   locations: [0, 1])!,
        startCenter: CGPoint(x: S / 2, y: S * 0.02), startRadius: 0,
        endCenter: CGPoint(x: S / 2, y: S * 0.02), endRadius: CGFloat(S * 0.82), options: [])

    // A little light for the orb to sit in, so the dots aren't pasted on flat black.
    ctx.drawRadialGradient(
        CGGradient(colorsSpace: space,
                   colors: [cg(ember, 0.34), cg(ember, 0)] as CFArray,
                   locations: [0, 1])!,
        startCenter: CGPoint(x: S / 2, y: S * 0.5), startRadius: 0,
        endCenter: CGPoint(x: S / 2, y: S * 0.5), endRadius: CGFloat(S * 0.46), options: [])

    drawOrb(in: ctx, canvas: S, share: shape == .iconGrid ? Mark.tileShare : 1.0,
            density: density) { depth in
        let (colour, alpha) = ink(depth: depth)
        return cg(colour, alpha)
    }

    ctx.restoreGState()
    return ctx.makeImage()!
}

/// The tray glyph: the same orb as a **template** image — black at varying
/// alpha on a clear ground, no tile — so macOS tints it to the menu bar's own
/// appearance. On the translucent menu bar an opaque colour tile looks pasted
/// on; and the orb has to be re-drawn rather than masked out of the tile,
/// because a brightness cut over a dot field keeps every dot and 450 of them in
/// an 18pt box is a smudge.
func renderTrayGlyph(pixels: Int) -> CGImage {
    let ctx = newContext(pixels)
    // ⚠️ Draw in *display* units and scale the context up, rather than drawing
    // at the asset's own resolution. Dot radius is a sub-linear function of the
    // box (`pow(box / 300, 0.6)`), so laying the field out on a 72-unit canvas
    // and then showing it at 18pt shrinks every dot by 4× — which is how this
    // first came out as faint grey pepper.
    let unit = Double(trayDisplayPixels)
    ctx.scaleBy(x: CGFloat(Double(pixels) / unit), y: CGFloat(Double(pixels) / unit))
    drawOrb(in: ctx, canvas: unit, share: 1.0, density: Density.tray) { depth in
        // Alpha alone carries depth: a template image throws colour away, so
        // the ember ramp would flatten to one grey. The floor is high because
        // the menu bar tints this to a single thin ink — a dot at 0.3 alpha up
        // there isn't "far", it's absent.
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.62 + 0.38 * pow(depth, 0.85))
    }
    return ctx.makeImage()!
}

/// 18pt at 2×, the box `AppDelegate` asks for. The asset is written at 4× this
/// for Retina headroom.
let trayDisplayPixels = 36

/// The landing page nav/footer mark's box, in CSS pixels.
let wordmarkDisplayPixels = 24

/// `share` is how much of the canvas the orb's *container* occupies — the tile
/// for the icon, the whole box for the tray glyph. The density tier then takes
/// its cut of that.
/// Pass `density` to override the size-derived tier (the tray does).
func drawOrb(in ctx: CGContext, canvas S: Double, share: Double,
             density: Density? = nil, colour: (Double) -> CGColor) {
    let density = density ?? Density.forPixels(Int(S.rounded()))
    let box = S * share * density.orbShare
    let offset = (S - box) / 2

    if Int(S.rounded()) <= Density.stippleFloor {
        // ⚠️ Pulled in from the full box on purpose. The dot field leaves gaps
        // that let the tile read around and between it; a solid ball at the same
        // share covers the ground completely, so the 16px slot came out as a bare
        // ember circle while every larger size was a dark tile with a mark in it.
        // The rim is what keeps the small icon in the same family.
        drawSolidOrb(in: ctx, centre: CGPoint(x: S / 2, y: S / 2),
                     radius: box / 2 * 0.82, colour: colour)
        return
    }

    for dot in waveDots(box: box, density: density, t: Mark.time, gain: Mark.gain,
                        tilt: Mark.tilt, yaw: Mark.yaw)
        .sorted(by: { $0.z < $1.z }) {
        let r = max(0.5, dot.r)
        ctx.setFillColor(colour(dot.depth))
        // The engine draws y-down; CoreGraphics is y-up.
        let x = offset + dot.x, y = S - (offset + dot.y)
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
}

/// The 16pt stand-in: the ball the dot field describes, drawn as a lit sphere.
/// Shaded off the same `colour(depth:)` ramp, so it is the same object in the
/// same light — it just stops claiming a resolution it doesn't have.
func drawSolidOrb(in ctx: CGContext, centre: CGPoint, radius: Double, colour: (Double) -> CGColor) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let stops = stride(from: 0.0, through: 1.0, by: 0.1).map { colour(1 - $0 * 0.86) }
    let grad = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: nil)!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                              width: radius * 2, height: radius * 2))
    ctx.clip()
    // Off-centre, up and toward the viewer — where the dot field is brightest.
    let lit = CGPoint(x: centre.x - radius * 0.12, y: centre.y + radius * 0.18)
    ctx.drawRadialGradient(grad, startCenter: lit, startRadius: 0,
                           endCenter: centre, endRadius: CGFloat(radius * 1.18),
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

// MARK: - Output

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(path)\n".utf8))
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

func pngData(_ image: CGImage) -> Data {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode png\n".utf8))
        exit(1)
    }
    return data
}

/// Write a multi-frame `.ico`.
///
/// ⚠️ This exists so the favicon does **not** rely on the browser to resample.
/// A single 32px PNG favicon is downscaled to 16 for the tab strip, and a dot
/// field cannot be downscaled — the same rule that governs everything else
/// here. An `.ico` carries one independently drawn bitmap per size and the
/// browser picks the exact match, so 16 gets the solid-orb stand-in and 32/48
/// get real dot fields.
///
/// Frames are stored as PNG rather than BMP (allowed since Vista, and supported
/// by every browser this site targets), which is why each entry's payload is
/// just `pngData`.
func writeICO(_ frames: [CGImage], to path: String) {
    var out = Data()
    var header = Data()
    header.append(contentsOf: [0x00, 0x00])         // reserved
    header.append(contentsOf: [0x01, 0x00])         // type 1 = icon
    header.append(UInt8(frames.count)); header.append(0x00)

    let payloads = frames.map(pngData)
    // Directory entries are fixed-width, so the first payload starts after all
    // of them.
    var offset = 6 + 16 * frames.count
    var directory = Data()
    for (image, payload) in zip(frames, payloads) {
        // 0 means 256 in this field; nothing here is that big, but encode it
        // correctly rather than emitting a 0-width entry if someone adds a slot.
        directory.append(UInt8(image.width == 256 ? 0 : image.width))
        directory.append(UInt8(image.height == 256 ? 0 : image.height))
        directory.append(0x00)                       // palette size
        directory.append(0x00)                       // reserved
        directory.append(contentsOf: [0x01, 0x00])   // colour planes
        directory.append(contentsOf: [0x20, 0x00])   // 32 bits per pixel
        for shift in stride(from: 0, to: 32, by: 8) {
            directory.append(UInt8((UInt32(payload.count) >> UInt32(shift)) & 0xff))
        }
        for shift in stride(from: 0, to: 32, by: 8) {
            directory.append(UInt8((UInt32(offset) >> UInt32(shift)) & 0xff))
        }
        offset += payload.count
    }
    out.append(header)
    out.append(directory)
    payloads.forEach { out.append($0) }
    try! out.write(to: URL(fileURLWithPath: path))
}

func run(_ launchPath: String, _ args: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    try! task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 { exit(task.terminationStatus) }
}

let root = FileManager.default.currentDirectoryPath
let fm = FileManager.default
guard fm.fileExists(atPath: "\(root)/Sources/WhisperMaster/Resources") else {
    FileHandle.standardError.write(Data("run this from the repo root\n".utf8))
    exit(1)
}

writePNG(renderTile(pixels: 1024), to: "\(root)/Sources/WhisperMaster/Resources/WhisperMasterLogo.png")
print("· WhisperMasterLogo.png (1024)")

// The in-app ladder. `BrandLogo` asks for 34pt (sidebar) and 58pt (About), and
// a dot field cannot be downscaled — so each gets a tile whose field is laid
// out for *its* box, stored at 4× for Retina headroom. Full-bleed, because
// `BrandLogo` clips the corner itself. Keep these in step with
// `BrandAsset.appTile(points:)`; a size served by the wrong tier is not a
// crash, it is a quietly muddy logo.
let appTiles: [(name: String, display: Int)] = [
    ("WhisperMasterLogoSmall", 34),
    ("WhisperMasterLogoMedium", 58),
]
for tile in appTiles {
    writePNG(renderTile(pixels: tile.display * 4, displayUnits: tile.display, shape: .hostClipped),
             to: "\(root)/Sources/WhisperMaster/Resources/\(tile.name).png")
    print("· \(tile.name).png (\(tile.display)pt @4×)")
}

// 4× the 18pt tray box, so the glyph is crisp on Retina and on a hypothetical 3×.
writePNG(renderTrayGlyph(pixels: 72), to: "\(root)/Sources/WhisperMaster/Resources/WhisperMasterTrayGlyph.png")
print("· WhisperMasterTrayGlyph.png (72)")

// Every iconset slot drawn at its own density rather than resampled.
let iconset = "\(root)/build/WhisperMaster.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let slots: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for slot in slots {
    writePNG(renderTile(pixels: slot.pixels), to: "\(iconset)/\(slot.name).png")
}
run("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", "\(root)/Resources/AppIcon.icns"])
try? fm.removeItem(atPath: iconset)
print("· AppIcon.icns (\(slots.count) slots)")

// MARK: - The landing page
//
// The web mark is generated from this same frozen figure rather than
// hand-authored, so the site and the app cannot drift. The alternative was an
// SVG of the dot field, which would have been a second copy of the wave painter
// to keep in sync *and* would have broken at 16px anyway.
//
// The landing page is a separate repo checked out beside this one. Point
// WEB_DIR elsewhere to override; a missing directory is a skip, not an error,
// so this script still runs in a clone that only has the app.
let webDir = ProcessInfo.processInfo.environment["WEB_DIR"]
    ?? URL(fileURLWithPath: root).deletingLastPathComponent()
        .appendingPathComponent("whisper-master-landing-page").path

if fm.fileExists(atPath: "\(webDir)/app") {
    // One independently drawn bitmap per size the browser might ask for.
    writeICO([16, 32, 48].map { renderTile(pixels: $0, shape: .rounded) },
             to: "\(webDir)/app/favicon.ico")
    print("· favicon.ico (16, 32, 48)")

    // iOS rounds this itself, so it ships as a full square.
    writePNG(renderTile(pixels: 180, shape: .hostClipped), to: "\(webDir)/app/apple-icon.png")
    print("· apple-icon.png (180)")

    // The nav/footer lockup, laid out for its 24px box and written at 3× for
    // Retina. 24 rather than the old meter's 12px because the dot field needs
    // room to read as a sphere — below ~20 it collapses into the solid stand-in
    // (`Density.stippleFloor`).
    //
    // ⚠️ It is the **tile**, not `renderBareOrb`. The landing page's ground is
    // paper cream, and the ink ramp peaks at `warmWhite` — so a bare orb put its
    // nearest, brightest dots at near-white on a near-white background and the
    // mark read as a hollow scatter with its middle missing. The dark tile is
    // also simply the same object as the favicon and the Dock icon.
    writePNG(renderTile(pixels: wordmarkDisplayPixels * 3,
                        displayUnits: wordmarkDisplayPixels, shape: .rounded,
                        density: Density.wordmark),
             to: "\(webDir)/public/wordmark-orb.png")
    print("· wordmark-orb.png (\(wordmarkDisplayPixels)px @3×)")
} else {
    print("· web assets skipped (no landing page at \(webDir))")
}
