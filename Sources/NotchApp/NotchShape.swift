import SwiftUI

/// A notch-style shape: flush with the top screen edge, concave transitions where it meets the
/// bezel, and convex rounded bottom corners — so the panel reads as an extension of the notch.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set {
            bottomRadius = newValue.first
            topRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let br = min(bottomRadius, rect.height, rect.width / 2)
        let tr = min(topRadius, rect.height)

        // Start just outside the top-left, at the screen edge.
        p.move(to: CGPoint(x: rect.minX - tr, y: rect.minY))
        // Concave curve down into the left wall.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + tr),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        // Left wall down to the bottom-left corner.
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - br))
        // Convex bottom-left corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + br, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        // Bottom edge.
        p.addLine(to: CGPoint(x: rect.maxX - br, y: rect.maxY))
        // Convex bottom-right corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        // Right wall up.
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tr))
        // Concave curve out to the screen edge.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX + tr, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}
