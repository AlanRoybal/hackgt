import SwiftUI
import UIKit

// Figma "Foundations" variables (file vuY63Cyxj1fZyDHbMjwSL6). Light-mode *Strong* values and `inkTertiary` are the
// AA-adjusted ones from D-201 as the Figma file settled them; skyStrong isn't in the file yet and keeps D-201's value.

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
    public static let inkTertiary = Color(light: 0x676D7B, dark: 0x828796)

    public static let lavender = Color(light: 0xE4DDFB, dark: 0x3A3358)
    public static let lavenderStrong = Color(light: 0x5F4FCC, dark: 0xC9BEFF)
    public static let mint = Color(light: 0xD5F0E3, dark: 0x23423A)
    public static let mintStrong = Color(light: 0x237558, dark: 0x9FE0C2)
    public static let peach = Color(light: 0xFFE2D3, dark: 0x4A3128)
    public static let peachStrong = Color(light: 0x9E5129, dark: 0xFFBFA0)
    public static let sky = Color(light: 0xDCEBFA, dark: 0x233447)
    public static let skyStrong = Color(light: 0x3569A5, dark: 0xA9CCF2)
    public static let butter = Color(light: 0xFCF0C4, dark: 0x463E22)
    public static let butterStrong = Color(light: 0x866612, dark: 0xF2DB8A)
    public static let rose = Color(light: 0xFADADF, dark: 0x4A262D)
    public static let roseStrong = Color(light: 0xB23346, dark: 0xFFA9B5)

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

/// Avatar sizes (Figma "Avatar" component: 28 / 40 / 56 / 96). `row` is the conversation-row avatar
/// (Figma "Skeleton / Message row"); friend rows use `large`.
public enum AvatarSize {
    public static let small: CGFloat = 28
    public static let medium: CGFloat = 40
    public static let row: CGFloat = 48
    public static let large: CGFloat = 56
    public static let hero: CGFloat = 96
}

/// Shared list-cell geometry, so every grouped list lines up the same way.
public enum RowMetrics {
    /// Minimum height of a single-line list cell.
    public static let minHeight: CGFloat = 52
    /// Leading icon tile in settings-style rows.
    public static let iconTile: CGFloat = 30
    /// Hairline inset for rows that lead with an avatar: margin + avatar + gap, so it starts under the text.
    public static let avatarDividerInset: CGFloat = Space.m + AvatarSize.row + Space.s
    /// Hairline inset for friend rows (56-pt avatar).
    public static let friendDividerInset: CGFloat = Space.m + AvatarSize.large + Space.s
    /// Hairline inset for rows that lead with an icon tile.
    public static let iconDividerInset: CGFloat = Space.m + iconTile + Space.s
}

/// Figma "Motion" page / variable collection "Motion". Under Reduce Motion every move, scale and spring
/// becomes `fade` (opacity only) and idle loops stop; `press` and haptics are unchanged.
public enum Motion {
    // MARK: Springs (ease/spring-*)

    /// Spring values, for driving choreography from a clock (`Curve.spring`).
    public enum Springs {
        public static var standard: Spring { Spring(response: 0.3, dampingRatio: 0.8) }
        public static var settle: Spring { Spring(response: 0.4, dampingRatio: 1.0) }
        public static var snappy: Spring { Spring(response: 0.4, dampingRatio: 0.68) }
        public static var pop: Spring { Spring(duration: 0.6, bounce: 0.35) }
        public static var playful: Spring { Spring(duration: 0.9, bounce: 0.5) }
    }

    /// Banners, sheets, toasts (bounce 0.2).
    public static let standard = Animation.spring(Springs.standard)
    /// Moves and repositioning, no overshoot.
    public static let settle = Animation.spring(Springs.settle)
    /// Lift / press release (bounce 0.32).
    public static let snappy = Animation.spring(Springs.snappy)
    /// Primary action arriving last, chips popping in (bounce 0.35).
    public static let pop = Animation.spring(Springs.pop)
    /// Expressive tier only: hero art growing in with overshoot (bounce 0.5).
    public static let playful = Animation.spring(Springs.playful)
    /// Press-down to 0.96 and back.
    public static let press = Animation.easeOut(duration: Durations.press)
    /// Reduce Motion replacement for everything: a short cross-fade.
    public static let fade = Animation.easeInOut(duration: Durations.fade)

    /// Same as `settle`.
    public static let move = settle
    /// Same as `standard`.
    public static let sheet = standard
    /// Mini-window corner snap after a flick (Prototypes page, unchanged).
    public static let snap = Animation.spring(response: 0.4, dampingFraction: 0.8)
    /// Photo swap in the mini window (Prototypes page, unchanged).
    public static let photoSwap = Animation.spring(response: 0.35, dampingFraction: 1.0)

    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }

    // MARK: Timing (duration/*, stagger/*, period/*), seconds

    public enum Durations {
        public static let press: TimeInterval = 0.12
        public static let tint: TimeInterval = 0.15
        public static let fade: TimeInterval = 0.2
        public static let banner: TimeInterval = 0.3
        public static let photoSwap: TimeInterval = 0.35
        public static let move: TimeInterval = 0.4
        /// Utility screens: each element fades up 8 pt.
        public static let entranceSubtle: TimeInterval = 0.35
        /// Onboarding / idle screens: whole choreography settled.
        public static let entranceExpressive: TimeInterval = 1.25
        /// Welcome page change: outgoing art stretches to 106% height (ease-in).
        public static let stretchOut: TimeInterval = 0.25
        /// Incoming art settles from 106% (ease-out).
        public static let stretchIn: TimeInterval = 0.4
        /// In-call header and controls fading away after idle (M18a).
        public static let chromeHide: TimeInterval = 0.25
    }

    public enum Stagger {
        public static let subtle: TimeInterval = 0.03
        public static let expressive: TimeInterval = 0.08
    }

    /// Idle loop periods. All are off (static at rest) under Reduce Motion.
    public enum Period {
        /// Art ±1.4°, backdrop ∓2.2°.
        public static let sway: TimeInterval = 6.5
        /// ±4 pt float and 104% backdrop breathe. The token table rounds this to 3.2 s; the keyframes use 3.25 s.
        public static let float: TimeInterval = 3.25
        public static let breathe: TimeInterval = 2.4
        public static let pulse: TimeInterval = 1.6
        public static let shimmer: TimeInterval = 1.2
    }

    // MARK: Curves (ease/*) as pure functions of t, so choreography is unit-testable

    public enum Curve {
        /// Linear progress of `t` through `start...end`, clamped to 0...1.
        public static func progress(_ t: Double, from start: Double, to end: Double) -> Double {
            guard end > start else { return t >= end ? 1 : 0 }
            return min(max((t - start) / (end - start), 0), 1)
        }

        /// ease/out-cubic, cubic-bezier(0.33, 1, 0.68, 1): fades and slide-ups.
        public static func outCubic(_ x: Double) -> Double {
            let p = 1 - x
            return 1 - p * p * p
        }

        /// ease/in-cubic, cubic-bezier(0.32, 0, 0.67, 0): outgoing content only.
        public static func inCubic(_ x: Double) -> Double { x * x * x }

        /// Reduce Motion's ease-in-and-out.
        public static func inOutCubic(_ x: Double) -> Double {
            x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        }

        /// 0 → 1 (with the spring's overshoot) for a spring released at `start`.
        public static func spring(_ spring: Spring, _ t: Double, from start: Double) -> Double {
            t <= start ? 0 : spring.value(target: 1.0, time: t - start)
        }

        /// ease/sine-in-out idle loop: sin(2πt / period), 0 before `start`.
        public static func oscillate(_ t: Double, period: Double, from start: Double = 0) -> Double {
            t <= start || period <= 0 ? 0 : sin(2 * .pi * (t - start) / period)
        }
    }
}

/// A clock that can be paused and resumed without jumping, for TimelineView-driven choreography
/// (idle loops pause while the user touches or the app isn't active).
public struct MotionClock: Equatable, Sendable {
    private var banked: TimeInterval = 0
    private var runningSince: Date?

    public init(startedAt date: Date? = nil) { runningSince = date }

    public var isRunning: Bool { runningSince != nil }

    public mutating func setRunning(_ running: Bool, at date: Date) {
        guard running != isRunning else { return }
        if let since = runningSince {
            banked += max(date.timeIntervalSince(since), 0)
            runningSince = nil
        } else {
            runningSince = date
        }
    }

    /// Seconds the clock has run as of `date`.
    public func time(at date: Date) -> TimeInterval {
        banked + (runningSince.map { max(date.timeIntervalSince($0), 0) } ?? 0)
    }
}

public enum Typography {
    /// Large titles and friend names: SF Pro Rounded Semibold.
    public static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .semibold)
    /// Figma "Title 3 Rounded": sheet titles, call header.
    public static let title = Font.system(.title3, design: .rounded, weight: .semibold)
    /// Figma "Title 3": empty-state titles.
    public static let title3 = Font.title3.weight(.semibold)
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

    /// Every sheet: the 28-pt sheet radius over the app background.
    public func nudgeSheet() -> some View {
        presentationCornerRadius(Radius.sheet)
            .presentationBackground(Palette.bg)
    }
}
