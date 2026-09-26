import DesignSystem
import SwiftUI

/// Welcome spot art (Figma Illustration/calendar, /call, /photos), drawn from tokens so it follows dark mode.
/// The backdrop is a separate layer because it scales, breathes and sways independently of the art.
/// Geometry is the Figma 300 × 225 frame.
struct WelcomeArt: View {
    enum Kind: CaseIterable { case calendar, call, photos }

    static let size = CGSize(width: 300, height: 225)

    let kind: Kind

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch kind {
            case .calendar: calendar
            case .call: call
            case .photos: photos
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// 250 × 180 oval behind the art.
    struct Backdrop: View {
        let kind: Kind

        var body: some View {
            Ellipse()
                .fill(color)
                .frame(width: 250, height: 180)
                .frame(width: WelcomeArt.size.width, height: WelcomeArt.size.height)
                .offset(y: 7.5) // Figma inset: 30 pt top, 15 pt bottom
                .accessibilityHidden(true)
        }

        private var color: Color {
            switch kind {
            case .calendar: Palette.sky
            case .call: Palette.surfaceAlt
            case .photos: Palette.peach
            }
        }
    }

    // MARK: - Calendar

    private var calendar: some View {
        Group {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface)
                .place(x: 77.5, y: 50, width: 145, height: 130)
            UnevenRoundedRectangle(topLeadingRadius: 16.25, topTrailingRadius: 16.25, style: .continuous)
                .fill(Art.lavender)
                .place(x: 77.5, y: 50, width: 145, height: 32.5)
            ForEach(0..<3, id: \.self) { row in
                ForEach(0..<4, id: \.self) { col in
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.surfaceAlt)
                        .place(x: 92.5 + 32.5 * Double(col), y: 95 + 27.5 * Double(row), width: 22.5, height: 17.5)
                }
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Art.mint)
                .place(x: 125, y: 122.5, width: 55, height: 17.5)
            Circle().fill(Art.mint)
                .place(x: 200, y: 147.5, width: 45, height: 45)
            Path { p in
                p.move(to: CGPoint(x: 2.5, y: 10))
                p.addLine(to: CGPoint(x: 10, y: 17.5))
                p.addLine(to: CGPoint(x: 23.75, y: 2.5))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            .place(x: 210, y: 160, width: 26.25, height: 20)
        }
    }

    // MARK: - Call

    private var call: some View {
        Group {
            face(x: 65, skin: Palette.peach, hair: Palette.lavenderStrong)
            face(x: 160, skin: Palette.butter, hair: Art.mint)
            Path { p in
                p.move(to: CGPoint(x: 1.875, y: 13.125))
                p.addCurve(to: CGPoint(x: 21.875, y: 13.125),
                           control1: CGPoint(x: 8.542, y: -1.875), control2: CGPoint(x: 15.209, y: -1.875))
            }
            .stroke(Art.lavender, style: StrokeStyle(lineWidth: 3.75, lineCap: .round))
            .place(x: 138.125, y: 74.375, width: 23.75, height: 15)
            Heart().fill(Art.rose)
                .place(x: 132.956, y: 50.357, width: 34.088, height: 29.634)
            Capsule().fill(Palette.mint).place(x: 65, y: 162.5, width: 75, height: 12.5)
            Capsule().fill(Palette.lavender).place(x: 160, y: 162.5, width: 75, height: 12.5)
        }
    }

    private func face(x: Double, skin: Color, hair: Color) -> some View {
        Group {
            Circle().fill(skin).place(x: x, y: 77.5, width: 75, height: 75)
            Hair().fill(hair).place(x: x, y: 77.5, width: 75, height: 37.5)
            Circle().fill(Palette.ink).place(x: x + 21.37, y: 117.63, width: 6, height: 6)
            Circle().fill(Palette.ink).place(x: x + 47.62, y: 117.63, width: 6, height: 6)
            Path { p in
                p.move(to: CGPoint(x: 1.5625, y: 1.5625))
                p.addCurve(to: CGPoint(x: 24.0625, y: 1.5625),
                           control1: CGPoint(x: 9.0625, y: 7.8125), control2: CGPoint(x: 16.5625, y: 7.8125))
            }
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 3.125, lineCap: .round))
            .place(x: x + 24.69, y: 130.31, width: 25.625, height: 7.8125)
        }
    }

    // MARK: - Photos

    private var photos: some View {
        Group {
            RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.lavender)
                .frame(width: 105, height: 105)
                .rotationEffect(.degrees(-8))
                .position(x: 125, y: 117.5)
            RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.surface)
                .place(x: 120, y: 57.5, width: 110, height: 110)
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sky)
                .place(x: 130, y: 67.5, width: 90, height: 70)
            Circle().fill(Art.butter)
                .place(x: 191.25, y: 78.75, width: 17.5, height: 17.5)
            Mountains().fill(Art.mint)
                .place(x: 130, y: 102.5, width: 90, height: 36.34)
            Capsule().fill(Palette.ink.opacity(0.25))
                .place(x: 130, y: 147.5, width: 50, height: 7.5)
        }
    }

    // MARK: - Shapes (Figma vector paths, in their own boxes)

    private struct Hair: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 37.5))
                p.addCurve(to: CGPoint(x: 10.98, y: 10.98), control1: CGPoint(x: 0, y: 27.55), control2: CGPoint(x: 3.95, y: 18.02))
                p.addCurve(to: CGPoint(x: 37.5, y: 0), control1: CGPoint(x: 18.02, y: 3.95), control2: CGPoint(x: 27.55, y: 0))
                p.addCurve(to: CGPoint(x: 64.02, y: 10.98), control1: CGPoint(x: 47.45, y: 0), control2: CGPoint(x: 56.98, y: 3.95))
                p.addCurve(to: CGPoint(x: 75, y: 37.5), control1: CGPoint(x: 71.05, y: 18.02), control2: CGPoint(x: 75, y: 27.55))
                p.addCurve(to: CGPoint(x: 0, y: 37.5), control1: CGPoint(x: 50, y: 25), control2: CGPoint(x: 25, y: 25))
                p.closeSubpath()
            }
        }
    }

    private struct Heart: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: 17.044, y: 4.634))
                p.addCurve(to: CGPoint(x: 2.044, y: 14.634), control1: CGPoint(x: 9.544, y: -5.366), control2: CGPoint(x: -5.456, y: 2.134))
                p.addLine(to: CGPoint(x: 17.044, y: 29.634))
                p.addLine(to: CGPoint(x: 32.044, y: 14.634))
                p.addCurve(to: CGPoint(x: 17.044, y: 4.634), control1: CGPoint(x: 39.544, y: 2.134), control2: CGPoint(x: 24.544, y: -5.366))
                p.closeSubpath()
            }
        }
    }

    private struct Mountains: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 27.5))
                p.addLine(to: CGPoint(x: 27.5, y: 0))
                p.addLine(to: CGPoint(x: 50, y: 22.5))
                p.addLine(to: CGPoint(x: 62.5, y: 10))
                p.addLine(to: CGPoint(x: 90, y: 35))
                p.addCurve(to: CGPoint(x: 85, y: 36.34), control1: CGPoint(x: 88.48, y: 35.88), control2: CGPoint(x: 86.76, y: 36.34))
                p.addCurve(to: CGPoint(x: 80, y: 35), control1: CGPoint(x: 83.24, y: 36.34), control2: CGPoint(x: 81.52, y: 35.88))
                p.closeSubpath()
            }
        }
    }

    /// Mid-tone art fills. They're raw colors in Figma (not variables) and read on both light and dark backdrops.
    private enum Art {
        static let lavender = Color(light: 0x8B7CE0, dark: 0x8B7CE0)
        static let mint = Color(light: 0x7FD1AE, dark: 0x7FD1AE)
        static let rose = Color(light: 0xEC8FA0, dark: 0xEC8FA0)
        static let butter = Color(light: 0xE8C75C, dark: 0xE8C75C)
    }
}

private extension View {
    /// Places a layer at its Figma frame inside the 300 × 225 art canvas.
    func place(x: Double, y: Double, width: Double, height: Double) -> some View {
        frame(width: width, height: height).position(x: x + width / 2, y: y + height / 2)
    }
}
