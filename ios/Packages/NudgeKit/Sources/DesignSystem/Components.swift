import Models
import SwiftUI

// MARK: Avatar

public struct AvatarView: View {
    let name: String
    let url: URL?
    let size: CGFloat
    let ring: Bool
    let ringOpacity: Double
    let seed: String

    public init(name: String, url: URL? = nil, size: CGFloat = 40, ring: Bool = false, ringOpacity: Double = 1, seed: String? = nil) {
        self.name = name
        self.url = url
        self.size = size
        self.ring = ring
        self.ringOpacity = ringOpacity
        self.seed = seed ?? name
    }

    public init(user: PublicUser, name: String? = nil, size: CGFloat = 40, ring: Bool = false, ringOpacity: Double = 1) {
        self.init(name: name ?? user.displayName, url: user.avatarUrl, size: size, ring: ring, ringOpacity: ringOpacity, seed: user.id)
    }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    public var body: some View {
        let tint = Palette.Tint.forSeed(seed)
        // The ring sits inside the frame so ringed and plain avatars align in lists.
        let gap = ring ? max(3, size * 0.07) : 0
        let inner = size - gap * 2
        ZStack {
            if ring { Circle().strokeBorder(Palette.mintStrong, lineWidth: max(2, size * 0.045)).opacity(ringOpacity) }
            ZStack {
                Circle().fill(tint.fill)
                Text(initials)
                    .font(.system(size: inner * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint.strong)
                if let url, url.scheme?.hasPrefix("http") == true {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                    .clipShape(Circle())
                }
            }
            .frame(width: inner, height: inner)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Two overlapping avatars (nudge banner, waiting room).
public struct AvatarPair: View {
    let left: (name: String, url: URL?, seed: String)
    let right: (name: String, url: URL?, seed: String)
    let size: CGFloat
    let borderColor: Color
    let spread: CGFloat
    let leftScale: CGFloat
    let rightScale: CGFloat

    /// `spread` pushes each avatar outward (they nudge together as it animates to 0); the scales let each breathe.
    public init(me: PublicUser?, friend: PublicUser, friendName: String, size: CGFloat = 40, borderColor: Color = Palette.surface,
                spread: CGFloat = 0, leftScale: CGFloat = 1, rightScale: CGFloat = 1) {
        left = (me?.displayName ?? "Me", me?.avatarUrl, me?.id ?? "me")
        right = (friendName, friend.avatarUrl, friend.id)
        self.size = size
        self.borderColor = borderColor
        self.spread = spread
        self.leftScale = leftScale
        self.rightScale = rightScale
    }

    public var body: some View {
        HStack(spacing: -size * 0.28) {
            AvatarView(name: left.name, url: left.url, size: size, seed: left.seed)
                .overlay(Circle().strokeBorder(borderColor, lineWidth: 3))
                .scaleEffect(leftScale)
                .offset(x: -spread)
            AvatarView(name: right.name, url: right.url, size: size, seed: right.seed)
                .overlay(Circle().strokeBorder(borderColor, lineWidth: 3))
                .scaleEffect(rightScale)
                .offset(x: spread)
        }
        .accessibilityHidden(true)
    }
}

// MARK: Rows

public struct FriendRow: View {
    let friend: Friend
    let status: String
    let statusTint: Color
    let pulse: Double

    /// `pulse` is the free ring / status dot opacity (they breathe while the friend is free).
    public init(friend: Friend, now: Date = Date(), pulse: Double = 1) {
        self.friend = friend
        self.pulse = pulse
        if friend.freeNow {
            if let until = friend.freeUntil {
                status = "Free until \(until.formatted(date: .omitted, time: .shortened))"
            } else {
                status = "Free now"
            }
            statusTint = Palette.mintStrong
        } else if let last = friend.lastCallAt {
            status = "Last talked \(last.formatted(.relative(presentation: .named)))"
            statusTint = Palette.inkSecondary
        } else {
            status = "Busy"
            statusTint = Palette.inkSecondary
        }
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            AvatarView(user: friend.user, name: friend.name, size: 44, ring: friend.freeNow, ringOpacity: pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name).font(Typography.friendName).foregroundStyle(Palette.ink)
                HStack(spacing: Space.xxs) {
                    if friend.freeNow { Circle().fill(Palette.mintStrong).frame(width: 6, height: 6).opacity(pulse) }
                    Text(status).font(.subheadline).foregroundStyle(statusTint)
                }
            }
            Spacer(minLength: Space.xs)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkTertiary)
        }
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

public struct SectionHeader: View {
    let title: String
    let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSecondary).textCase(.uppercase).tracking(0.6)
            Spacer()
            if let trailing { Text(trailing).font(.footnote).foregroundStyle(Palette.inkTertiary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Chips

public struct TopicChip: View {
    let title: String
    let onRemove: (() -> Void)?

    public init(_ title: String, onRemove: (() -> Void)? = nil) {
        self.title = title
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.butterStrong)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Palette.butterStrong)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.leading, Space.s)
        .padding(.trailing, onRemove == nil ? Space.s : Space.xs)
        .padding(.vertical, 7)
        .background(Palette.butter, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}

public struct Pill: View {
    let text: String
    let tint: Palette.Tint
    let systemImage: String?

    public init(_ text: String, tint: Palette.Tint = .lavender, systemImage: String? = nil) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: Space.xxs) {
            if let systemImage { Image(systemName: systemImage).font(.caption.weight(.semibold)) }
            Text(text).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(tint.strong)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 6)
        .background(tint.fill, in: Capsule())
    }
}

/// Wraps chips onto multiple lines.
public struct FlowLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = Space.xs) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: Toast

public struct ToastView: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(Palette.bg)
            if let actionTitle, let action {
                Divider().frame(height: 18).overlay(Palette.bg.opacity(0.3))
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.lavender)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Palette.ink, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

// MARK: Empty / loading / error

public struct EmptyStateView: View {
    let illustration: Illustration.Kind
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(_ illustration: Illustration.Kind, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.illustration = illustration
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        // Figma M27a/d: the block fades up 12 pt, then the art floats and sways against its backdrop.
        MotionTimeline(loops: true) { beat in
            VStack(spacing: Space.m) {
                IdleArt(beat: beat, idleFrom: Self.idleFrom) {
                    Illustration(illustration).frame(width: 150, height: 110)
                } backdrop: {
                    Ellipse().fill(Palette.surfaceAlt).frame(width: 190, height: 130)
                }
                .frame(width: 190, height: 130)
                VStack(spacing: Space.xs) {
                    Text(title).font(Typography.title).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                    Text(message).font(.body).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
                }
                if let actionTitle, let action {
                    NudgeButton(actionTitle, kind: .primary, size: .medium, fullWidth: false, action: action).padding(.top, Space.xs)
                }
            }
            .motionLayer(beat.fadeUp(at: 0, fade: Motion.Durations.entranceSubtle, rise: Motion.Durations.entranceSubtle))
        }
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: .infinity)
    }

    static let idleFrom = Motion.Durations.entranceSubtle
}

/// Loading placeholder. Rows pulse 100 → 55% every 1.2 s, each 0.08 s behind the one above (a top-to-bottom
/// wave). Reduce Motion: static at 70%.
public struct SkeletonRow: View {
    let index: Int

    public init(index: Int = 0) { self.index = index }

    public var body: some View {
        MotionTimeline(settlesAt: 0, loops: true) { beat in
            HStack(spacing: Space.s) {
                Circle().fill(Palette.surfaceAlt).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: Space.xs) {
                    RoundedRectangle(cornerRadius: 4).fill(Palette.surfaceAlt).frame(width: 140, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Palette.surfaceAlt).frame(width: 90, height: 10)
                }
                Spacer()
            }
            .padding(.vertical, Space.s)
            .opacity(beat.reduceMotion ? 0.7
                : IdleMotion.dim(beat.t, period: Motion.Period.shimmer, low: 0.55, offset: Motion.Stagger.expressive * Double(index)))
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

public struct Banner: View {
    public enum Style: Sendable { case offline, warning, info }
    let text: String
    let style: Style

    public init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        let tint: Palette.Tint = switch style {
        case .offline: .butter
        case .warning: .peach
        case .info: .sky
        }
        HStack(spacing: Space.xs) {
            Image(systemName: style == .offline ? "wifi.slash" : style == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
            Text(text).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(tint.strong)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(tint.fill, in: Capsule())
    }
}

// MARK: Inputs

public struct NudgeTextFieldStyle: TextFieldStyle {
    public enum State: Sendable { case normal, focused, valid, error }
    let state: State

    public init(_ state: State = .normal) { self.state = state }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.body)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.m)
            .frame(minHeight: 52)
            .background(Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: state == .normal ? 0 : 1.5)
            }
    }

    var borderColor: Color {
        switch state {
        case .normal: .clear
        case .focused: Palette.lavenderStrong
        case .valid: Palette.mintStrong
        case .error: Palette.roseStrong
        }
    }
}

/// Grouped container for settings-style rows.
public struct CardList<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(spacing: 0) { content }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

public struct RowDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(Palette.divider).frame(height: 1).padding(.leading, Space.m)
    }
}
