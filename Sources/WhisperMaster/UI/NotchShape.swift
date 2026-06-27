import SwiftUI

/// The black body that appears molded to the notch.
///
/// The top corners use a *concave* (inverted) radius that flares outward to the
/// full width at the very top edge, so the surface looks like it flows out of
/// the notch/bezel rather than being a rectangle stuck below it. The bottom
/// corners are conventionally rounded where the body hangs into the screen.
struct NotchShape: Shape {
    /// Radius of the concave flare where the top meets the bezel.
    var topConcaveRadius: CGFloat = 12
    /// Radius of the rounded bottom corners.
    var bottomCornerRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let tc = min(topConcaveRadius, rect.width / 2, max(0, rect.height))
        let br = min(bottomCornerRadius, max(0, rect.width / 2 - tc), max(0, rect.height - tc))

        var path = Path()

        // Top-left: flush at the bezel, flaring concavely down into the wall.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tc, y: rect.minY + tc),
            control: CGPoint(x: rect.minX + tc, y: rect.minY)
        )

        // Left wall down to the bottom-left convex corner.
        path.addLine(to: CGPoint(x: rect.minX + tc, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tc + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tc, y: rect.maxY)
        )

        // Bottom edge to the bottom-right convex corner.
        path.addLine(to: CGPoint(x: rect.maxX - tc - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tc, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tc, y: rect.maxY)
        )

        // Right wall up to the top-right concave flare.
        path.addLine(to: CGPoint(x: rect.maxX - tc, y: rect.minY + tc))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tc, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
