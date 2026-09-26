import DesignSystem
import SwiftUI

/// Flat illustrated stand-ins for camera frames and photos, used in screenshot mode and as the
/// fallback when a photo URL fails. No bundled raster images.
struct SceneryPhoto: View {
    let name: String

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                switch kind {
                case .hike:
                    Color(red: 0.73, green: 0.86, blue: 0.96)
                    Circle().fill(Color(red: 1, green: 0.86, blue: 0.55)).frame(width: w * 0.22).position(x: w * 0.74, y: h * 0.22)
                    Mountain().fill(Color(red: 0.47, green: 0.62, blue: 0.72)).frame(width: w * 1.2, height: h * 0.55).position(x: w * 0.35, y: h * 0.72)
                    Mountain().fill(Color(red: 0.34, green: 0.54, blue: 0.47)).frame(width: w * 1.1, height: h * 0.42).position(x: w * 0.8, y: h * 0.82)
                    Rectangle().fill(Color(red: 0.42, green: 0.62, blue: 0.4)).frame(height: h * 0.14).position(x: w / 2, y: h * 0.95)
                case .cake:
                    Color(red: 0.99, green: 0.92, blue: 0.86)
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.96, green: 0.78, blue: 0.82)).frame(width: w * 0.62, height: h * 0.2).position(x: w / 2, y: h * 0.68)
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.98, green: 0.88, blue: 0.9)).frame(width: w * 0.46, height: h * 0.16).position(x: w / 2, y: h * 0.51)
                    Capsule().fill(Color(red: 0.55, green: 0.5, blue: 0.85)).frame(width: w * 0.035, height: h * 0.1).position(x: w / 2, y: h * 0.38)
                    Circle().fill(Color(red: 1, green: 0.78, blue: 0.4)).frame(width: w * 0.05).position(x: w / 2, y: h * 0.31)
                    Rectangle().fill(Color(red: 0.86, green: 0.74, blue: 0.62)).frame(height: h * 0.14).position(x: w / 2, y: h * 0.86)
                case .beach:
                    Color(red: 0.8, green: 0.91, blue: 0.98)
                    Rectangle().fill(Color(red: 0.42, green: 0.7, blue: 0.86)).frame(height: h * 0.3).position(x: w / 2, y: h * 0.62)
                    Rectangle().fill(Color(red: 0.98, green: 0.88, blue: 0.7)).frame(height: h * 0.3).position(x: w / 2, y: h * 0.88)
                    Circle().fill(Color(red: 1, green: 0.8, blue: 0.5)).frame(width: w * 0.2).position(x: w * 0.25, y: h * 0.24)
                case .dog:
                    Color(red: 0.93, green: 0.95, blue: 0.88)
                    Ellipse().fill(Color(red: 0.8, green: 0.6, blue: 0.4)).frame(width: w * 0.55, height: h * 0.34).position(x: w / 2, y: h * 0.68)
                    Circle().fill(Color(red: 0.8, green: 0.6, blue: 0.4)).frame(width: w * 0.36).position(x: w * 0.5, y: h * 0.42)
                    Ellipse().fill(Color(red: 0.6, green: 0.42, blue: 0.28)).frame(width: w * 0.12, height: h * 0.16).position(x: w * 0.36, y: h * 0.38)
                    Ellipse().fill(Color(red: 0.6, green: 0.42, blue: 0.28)).frame(width: w * 0.12, height: h * 0.16).position(x: w * 0.64, y: h * 0.38)
                }
            }
        }
        .clipped()
    }

    enum Kind { case hike, cake, beach, dog }
    var kind: Kind {
        let n = name.lowercased()
        if n.contains("cake") || n.contains("birthday") { return .cake }
        if n.contains("beach") || n.contains("lake") { return .beach }
        if n.contains("dog") || n.contains("max") { return .dog }
        return .hike
    }
}

struct Mountain: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Illustrated "video frame" of a person for screenshot mode.
struct PreviewVideoFrame: View {
    enum Style { case remote, me }
    let style: Style

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                (style == .remote ? Color(red: 0.36, green: 0.33, blue: 0.42) : Color(red: 0.3, green: 0.36, blue: 0.4))
                Rectangle().fill(style == .remote ? Color(red: 0.46, green: 0.41, blue: 0.5) : Color(red: 0.38, green: 0.45, blue: 0.48))
                    .frame(width: w * 0.3, height: h).position(x: w * 0.12, y: h / 2)
                Ellipse().fill(style == .remote ? Color(red: 0.55, green: 0.45, blue: 0.62) : Color(red: 0.42, green: 0.55, blue: 0.62))
                    .frame(width: w * 0.9, height: h * 0.5).position(x: w * 0.5, y: h * 0.98)
                Circle().fill(Color(red: 0.87, green: 0.72, blue: 0.62))
                    .frame(width: min(w, h) * 0.42).position(x: w * 0.5, y: h * 0.5)
                Capsule().fill(style == .remote ? Color(red: 0.3, green: 0.22, blue: 0.2) : Color(red: 0.2, green: 0.18, blue: 0.16))
                    .frame(width: min(w, h) * 0.46, height: min(w, h) * 0.2).position(x: w * 0.5, y: h * 0.5 - min(w, h) * 0.18)
            }
        }
    }
}
