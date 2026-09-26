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
        case .large: 54
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
        let shape = RoundedRectangle(cornerRadius: size == .small ? Radius.chip + 2 : Radius.input + 2, style: .continuous)
        return configuration.label
            .font(size.font)
            .foregroundStyle(kind.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, size == .small ? Space.s : Space.l)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: size.height)
            .background {
                shape.fill(kind.fill.opacity(configuration.isPressed ? 0.75 : 1))
                    .animation(.easeInOut(duration: Motion.Durations.tint), value: configuration.isPressed)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
            .pressFeedback(configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.45)
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

/// Round 56-pt in-call control.
public struct CallControlButton: View {
    public enum Role: Sendable { case normal, active, end }
    let systemImage: String
    let label: String
    let role: Role
    let action: () -> Void

    public init(systemImage: String, label: String, role: Role = .normal, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(RoundCallStyle(role: role))
        .accessibilityLabel(label)
    }
}

struct RoundCallStyle: ButtonStyle {
    let role: CallControlButton.Role

    func makeBody(configuration: Configuration) -> some View {
        let (fill, ink): (Color, Color) = switch role {
        case .normal: (Color.white.opacity(0.16), Palette.callInk)
        case .active: (Color(uiColor: UIColor(hex: 0xF2F1F6)), Color(uiColor: UIColor(hex: 0x1F2330)))
        case .end: (Color(uiColor: UIColor(hex: 0xFADADF)), Color(uiColor: UIColor(hex: 0xB13647)))
        }
        return configuration.label
            .foregroundStyle(ink)
            .background {
                Circle().fill(fill.opacity(configuration.isPressed ? 0.7 : 1))
                    .animation(.easeInOut(duration: Motion.Durations.tint), value: configuration.isPressed)
            }
            .pressFeedback(configuration.isPressed, scale: 0.92) // Figma M18a: in-call controls press deeper
    }
}
