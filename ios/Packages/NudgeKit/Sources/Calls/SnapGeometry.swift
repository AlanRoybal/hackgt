import CoreGraphics
import Foundation

/// Mini-window corner snapping with momentum projection (CALL-1, apple-design rule 6).
public enum SnapGeometry {
    public enum Corner: CaseIterable, Sendable, Hashable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    /// Apple's projection: where a flick with `velocity` (pts/s) comes to rest.
    public static func project(_ velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// Center of the window when parked in `corner`.
    public static func center(of corner: Corner, container: CGSize, window: CGSize, insets: EdgeInsetsLike) -> CGPoint {
        let left = insets.leading + window.width / 2
        let right = container.width - insets.trailing - window.width / 2
        let top = insets.top + window.height / 2
        let bottom = container.height - insets.bottom - window.height / 2
        switch corner {
        case .topLeading: return CGPoint(x: left, y: top)
        case .topTrailing: return CGPoint(x: right, y: top)
        case .bottomLeading: return CGPoint(x: left, y: bottom)
        case .bottomTrailing: return CGPoint(x: right, y: bottom)
        }
    }

    /// Picks the corner nearest to where the gesture is *going*, not where it was released.
    public static func target(release: CGPoint, velocity: CGVector, container: CGSize, window: CGSize, insets: EdgeInsetsLike) -> Corner {
        let projected = CGPoint(x: release.x + project(velocity.dx), y: release.y + project(velocity.dy))
        return Corner.allCases.min { a, b in
            distance(projected, center(of: a, container: container, window: window, insets: insets))
                < distance(projected, center(of: b, container: container, window: window, insets: insets))
        }!
    }

    /// Soft boundary resistance past the edges (rule 9).
    public static func rubberband(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// SwiftUI-free insets so the math is testable.
public struct EdgeInsetsLike: Sendable, Hashable {
    public var top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat
    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}
