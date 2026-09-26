import SwiftUI
import UIKit

// Appendix A tokens. Light-mode *Strong* values and `inkTertiary` are darkened just enough to
// pass WCAG AA (4.5:1) on their pastel fills and on white — see D-201 and ios/scripts/contrast.py.

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// A color that follows the current light/dark trait.
    public init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

public enum Palette {
    public static let bg = Color(light: 0xFBF8F4, dark: 0x15161C)
    public static let surface = Color(light: 0xFFFFFF, dark: 0x1E2028)
    public static let surfaceAlt = Color(light: 0xF4EFE9, dark: 0x262833)
    public static let divider = Color(light: 0xECE7E0, dark: 0x2F3240)
    public static let ink = Color(light: 0x1F2330, dark: 0xF2F1F6)
    public static let inkSecondary = Color(light: 0x5B6172, dark: 0xA9ADBB)
    public static let inkTertiary = Color(light: 0x6D727C, dark: 0x828796)

    public static let lavender = Color(light: 0xE4DDFB, dark: 0x3A3358)
    public static let lavenderStrong = Color(light: 0x6052BD, dark: 0xC9BEFF)
    public static let mint = Color(light: 0xD5F0E3, dark: 0x23423A)
    public static let mintStrong = Color(light: 0x277553, dark: 0x9FE0C2)
    public static let peach = Color(light: 0xFFE2D3, dark: 0x4A3128)
    public static let peachStrong = Color(light: 0x9F5130, dark: 0xFFBFA0)
    public static let sky = Color(light: 0xDCEBFA, dark: 0x233447)
    public static let skyStrong = Color(light: 0x3569A5, dark: 0xA9CCF2)
    public static let butter = Color(light: 0xFCF0C4, dark: 0x463E22)
    public static let butterStrong = Color(light: 0x83680F, dark: 0xF2DB8A)
    public static let rose = Color(light: 0xFADADF, dark: 0x4A262D)
    public static let roseStrong = Color(light: 0xB13647, dark: 0xFFA9B5)

    /// In-call chrome sits on video, so it's fixed dark regardless of appearance.
    public static let callScrim = Color(red: 0.08, green: 0.09, blue: 0.11)
    public static let callInk = Color(red: 0.95, green: 0.95, blue: 0.97)

    public enum Tint: CaseIterable, Sendable {
        case lavender, mint, peach, sky, butter, rose

        public var fill: Color {
            switch self {
            case .lavender: Palette.lavender
            case .mint: Palette.mint
            case .peach: Palette.peach
            case .sky: Palette.sky
            case .butter: Palette.butter
            case .rose: Palette.rose
            }
        }

        public var strong: Color {
            switch self {
            case .lavender: Palette.lavenderStrong
            case .mint: Palette.mintStrong
            case .peach: Palette.peachStrong
            case .sky: Palette.skyStrong
            case .butter: Palette.butterStrong
            case .rose: Palette.roseStrong
            }
        }

        /// Stable tint per name/id for avatars.
        public static func forSeed(_ seed: String) -> Tint {
            var h: UInt64 = 1469598103934665603
            for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            return allCases[Int(h % UInt64(allCases.count))]
        }
    }
}

public enum Space {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let margin: CGFloat = 20
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 40
    public static let xxxl: CGFloat = 56
}

public enum Radius {
    public static let chip: CGFloat = 8
    public static let input: CGFloat = 12
    public static let card: CGFloat = 20
    public static let sheet: CGFloat = 28
}

public enum Motion {
    /// Move / reposition: critically damped (apple-design: 1.0 / 0.4).
    public static let move = Animation.spring(response: 0.4, dampingFraction: 1.0)
    /// Sheets, drawers, the nudge banner (0.8 / 0.3).
    public static let sheet = Animation.spring(response: 0.3, dampingFraction: 0.8)
    /// Mini-window corner snap after a flick.
    public static let snap = Animation.spring(response: 0.4, dampingFraction: 0.8)
    /// Photo swap in the mini window.
    public static let photoSwap = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// Reduce Motion replacement: a short cross-fade.
    public static let fade = Animation.easeInOut(duration: 0.2)

    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

public enum Typography {
    /// Large titles and friend names: SF Pro Rounded Semibold.
    public static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .semibold)
    public static let title = Font.system(.title2, design: .rounded, weight: .semibold)
    public static let friendName = Font.system(.headline, design: .rounded, weight: .semibold)
    public static let friendNameLarge = Font.system(.title, design: .rounded, weight: .semibold)
    public static let headline = Font.headline
    public static let body = Font.body
    public static let callout = Font.callout
    public static let subheadline = Font.subheadline
    public static let footnote = Font.footnote
    public static let caption = Font.caption
    public static let caption2 = Font.caption2
}

extension View {
    /// Large display text wants slightly negative tracking (apple-design rule 15).
    public func displayTracking() -> some View { tracking(-0.4) }

    public func nudgeBackground() -> some View {
        background(Palette.bg.ignoresSafeArea())
    }

    /// Flat card: solid surface, no shadow.
    public func nudgeCard(padding: CGFloat = Space.m, fill: Color = Palette.surface) -> some View {
        self.padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
