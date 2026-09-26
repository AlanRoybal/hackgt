import SwiftUI

public enum NudgeButtonKind: Sendable {
    case primary, secondary, accept, skip, destructive, text

    var fill: Color {
        switch self {
        case .primary: Palette.lavender
        case .secondary: Palette.surfaceAlt
        case .accept: Palette.mint
        case .skip: Palette.peach
        case .destructive: Palette.rose
        case .text: .clear
        }
    }

    var ink: Color {
        switch self {
        case .primary: Palette.lavenderStrong
        case .secondary: Palette.ink
        case .accept: Palette.mintStrong
        case .skip: Palette.peachStrong
        case .destructive: Palette.roseStrong
        case .text: Palette.lavenderStrong
        }
    }
}

public enum NudgeButtonSize: Sendable {
    case large, medium, small

    var height: CGFloat {
        switch self {
        case .large: 50
        case .medium: 44
        case .small: 34
        }
    }

    var font: Font {
        switch self {
        case .large: .headline
        case .medium: .subheadline.weight(.semibold)
        case .small: .footnote.weight(.semibold)
        }
    }
}

/// Highlights on touch-down (isPressed flips on pointer-down), commits on release.
public struct NudgeButtonStyle: ButtonStyle {
    let kind: NudgeButtonKind
    let size: NudgeButtonSize
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: NudgeButtonKind = .primary, size: NudgeButtonSize = .large, fullWidth: Bool = true) {
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        // Figma "Button": full-radius capsule, 20-pt side padding; pressed darkens the fill with an ink overlay,
        // disabled drops to 40%.
        return configuration.label
            .font(size.font)
            .foregroundStyle(kind.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, size == .small ? Space.s : Space.margin)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: size.height)
            .background {
                Capsule().fill(kind.fill)
                    .overlay(Capsule().fill(Palette.ink.opacity(configuration.isPressed ? 0.08 : 0)))
                    .animation(.easeInOut(duration: Motion.Durations.tint), value: configuration.isPressed)
            }
            .contentShape(Capsule())
            .pressFeedback(configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Press feedback only, for text-style buttons that bring their own look (e.g. Skip).
public struct PressFeedbackButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeInOut(duration: Motion.Durations.tint), value: configuration.isPressed)
            .contentShape(Rectangle())
            .pressFeedback(configuration.isPressed)
    }
}

extension View {
    /// Figma "Press feedback": every tappable surface scales to 96% on touch-down (0.12 s ease-out) and springs
    /// back on release (snappy). Kept under Reduce Motion: it's feedback, not decoration.
    public func pressFeedback(_ isPressed: Bool, scale: CGFloat = 0.96) -> some View {
        scaleEffect(isPressed ? scale : 1)
            .animation(isPressed ? Motion.press : Motion.snappy, value: isPressed)
    }
}

/// Button with an inline loading state.
public struct NudgeButton: View {
    let title: String
    let systemImage: String?
    let kind: NudgeButtonKind
    let size: NudgeButtonSize
    let fullWidth: Bool
    let isLoading: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, kind: NudgeButtonKind = .primary, size: NudgeButtonSize = .large,
                fullWidth: Bool = true, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: Space.xs) {
                    if let systemImage { Image(systemName: systemImage) }
                    Text(title)
                }
                .opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(kind.ink) }
            }
        }
        .buttonStyle(NudgeButtonStyle(kind, size: size, fullWidth: fullWidth))
        .disabled(isLoading)
        .accessibilityLabel(title)
    }
}

/// Figma "Round call control": 56 pt in-call, 72 pt for incoming Accept / Decline.
public struct CallControlButton: View {
    public enum Role: Sendable { case normal, active, end, accept }
    let systemImage: String
    let label: String
    let role: Role
    let size: CGFloat
    let action: () -> Void

    public init(systemImage: String, label: String, role: Role = .normal, size: CGFloat = 56, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.role = role
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size > 56 ? 28 : 22, weight: .medium))
                .frame(width: size, height: size)
        }
        .buttonStyle(RoundCallStyle(role: role))
        .accessibilityLabel(label)
    }
}

struct RoundCallStyle: ButtonStyle {
    let role: CallControlButton.Role

    func makeBody(configuration: Configuration) -> some View {
        // Fixed colors in both modes: these always sit on video. Pressed adds a 12% black overlay.
        let (fill, ink): (Color, Color) = switch role {
        case .normal: (Color(uiColor: UIColor(hex: 0x1F2330, alpha: 0.6)), .white)
        case .active: (.white, Color(uiColor: UIColor(hex: 0x1F2330)))
        case .end: (Color(uiColor: UIColor(hex: 0xB23346)), .white)
        case .accept: (Color(uiColor: UIColor(hex: 0x237558)), .white)
        }
        return configuration.label
            .foregroundStyle(ink)
            .background {
                Circle().fill(fill)
                    .overlay(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
                    .animation(.easeInOut(duration: Motion.Durations.tint), value: configuration.isPressed)
            }
            .pressFeedback(configuration.isPressed, scale: 0.92) // Figma M18a: in-call controls press deeper
    }
}
