import SwiftUI

/// Flat, geometric spot illustrations drawn from the token palette (no raster assets).
public struct Illustration: View {
    public enum Kind: Sendable, CaseIterable {
        case free, call, photos, friends, messages, memories, calendar, notifications, contacts, camera, focus, motion, offline
    }

    let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                switch kind {
                case .free:
                    // Two calendar cards with a shared green slot.
                    card(Palette.lavender, w * 0.42, h * 0.78).rotationEffect(.degrees(-8)).offset(x: -w * 0.16)
                    card(Palette.sky, w * 0.42, h * 0.78).rotationEffect(.degrees(7)).offset(x: w * 0.16)
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.mintStrong)
                        .frame(width: w * 0.62, height: h * 0.14)
                case .call:
                    Circle().fill(Palette.mint).frame(width: h * 0.9)
                    Circle().fill(Palette.peach).frame(width: h * 0.42).offset(x: -w * 0.26, y: -h * 0.22)
                    Image(systemName: "phone.fill").font(.system(size: h * 0.32, weight: .semibold)).foregroundStyle(Palette.mintStrong)
                case .photos:
                    card(Palette.butter, w * 0.46, h * 0.62).rotationEffect(.degrees(-10)).offset(x: -w * 0.12, y: h * 0.04)
                    card(Palette.rose, w * 0.46, h * 0.62).rotationEffect(.degrees(6)).offset(x: w * 0.12)
                    Circle().fill(Palette.roseStrong.opacity(0.6)).frame(width: h * 0.12).offset(x: w * 0.2, y: -h * 0.12)
                    Triangle().fill(Palette.roseStrong.opacity(0.35)).frame(width: w * 0.3, height: h * 0.2).offset(x: w * 0.12, y: h * 0.12)
                case .friends:
                    Circle().fill(Palette.lavender).frame(width: h * 0.62).offset(x: -w * 0.16)
                    Circle().fill(Palette.mint).frame(width: h * 0.62).offset(x: w * 0.16)
                    Circle().fill(Palette.peach).frame(width: h * 0.34).offset(y: -h * 0.3)
                case .messages:
                    bubble(Palette.sky, w * 0.56, h * 0.42).offset(x: -w * 0.12, y: -h * 0.16)
                    bubble(Palette.lavender, w * 0.5, h * 0.36).scaleEffect(x: -1).offset(x: w * 0.14, y: h * 0.2)
                case .memories:
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.butter).frame(width: w * 0.6, height: h * 0.8)
                    VStack(spacing: h * 0.08) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(Palette.butterStrong.opacity(0.45)).frame(width: w * (i == 2 ? 0.26 : 0.4), height: h * 0.07)
                        }
                    }
                case .calendar:
                    card(Palette.sky, w * 0.56, h * 0.82)
                    Grid(horizontalSpacing: w * 0.04, verticalSpacing: h * 0.06) {
                        ForEach(0..<3, id: \.self) { r in
                            GridRow {
                                ForEach(0..<3, id: \.self) { c in
                                    RoundedRectangle(cornerRadius: 3).fill((r == 1 && c == 1) ? Palette.mintStrong : Palette.skyStrong.opacity(0.3))
                                        .frame(width: w * 0.1, height: h * 0.1)
                                }
                            }
                        }
                    }.offset(y: h * 0.06)
                case .notifications:
                    card(Palette.surfaceAlt, w * 0.7, h * 0.3).offset(y: -h * 0.22)
                    card(Palette.lavender, w * 0.8, h * 0.34).offset(y: h * 0.14)
                    Circle().fill(Palette.lavenderStrong).frame(width: h * 0.16).offset(x: -w * 0.28, y: h * 0.14)
                case .contacts:
                    card(Palette.peach, w * 0.52, h * 0.82)
                    Circle().fill(Palette.peachStrong.opacity(0.5)).frame(width: h * 0.26).offset(y: -h * 0.12)
                    Capsule().fill(Palette.peachStrong.opacity(0.35)).frame(width: w * 0.3, height: h * 0.08).offset(y: h * 0.16)
                case .camera:
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.rose).frame(width: w * 0.62, height: h * 0.62)
                    Circle().fill(Palette.roseStrong.opacity(0.55)).frame(width: h * 0.28)
                    Circle().fill(Palette.mint).frame(width: h * 0.14).offset(x: w * 0.22, y: -h * 0.2)
                case .focus:
                    Circle().fill(Palette.lavender).frame(width: h * 0.82)
                    Image(systemName: "moon.fill").font(.system(size: h * 0.34)).foregroundStyle(Palette.lavenderStrong)
                case .motion:
                    Capsule().fill(Palette.sky).frame(width: w * 0.78, height: h * 0.36)
                    Circle().fill(Palette.skyStrong.opacity(0.6)).frame(width: h * 0.18).offset(x: -w * 0.2, y: h * 0.18)
                    Circle().fill(Palette.skyStrong.opacity(0.6)).frame(width: h * 0.18).offset(x: w * 0.2, y: h * 0.18)
                case .offline:
                    Circle().fill(Palette.butter).frame(width: h * 0.82)
                    Image(systemName: "wifi.slash").font(.system(size: h * 0.3, weight: .semibold)).foregroundStyle(Palette.butterStrong)
                }
            }
            .frame(width: w, height: h)
        }
        .accessibilityHidden(true)
    }

    private func card(_ color: Color, _ w: CGFloat, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color).frame(width: w, height: h)
    }

    private func bubble(_ color: Color, _ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: h * 0.45, style: .continuous).fill(color).frame(width: w, height: h)
            Triangle().fill(color).frame(width: h * 0.3, height: h * 0.3).rotationEffect(.degrees(200)).offset(x: h * 0.1, y: h * 0.14)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
