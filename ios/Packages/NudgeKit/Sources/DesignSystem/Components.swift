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
            status = friend.freeUntilText(now: now).map { "Free until \($0)" } ?? "Free now"
            statusTint = Palette.mintStrong
        } else if let last = friend.lastCallAt {
            status = "Last talked \(last.formatted(.relative(presentation: .named)))"
            statusTint = Palette.inkSecondary
        } else {
            status = "Busy"
            statusTint = Palette.inkSecondary
        }
    }

    /// Figma "Friend row": 56-pt avatar, nickname + handle on one line, footnote status with a dot for free/busy.
    public var body: some View {
        HStack(spacing: Space.s) {
            AvatarView(user: friend.user, name: friend.name, size: AvatarSize.large, ring: friend.freeNow, ringOpacity: pulse)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(friend.name).font(Typography.friendName).foregroundStyle(Palette.ink).layoutPriority(1)
                    Text("@\(friend.user.handle)").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                }
                .lineLimit(1)
                HStack(spacing: 6) {
                    if friend.freeNow {
                        Circle().fill(Palette.mintStrong).frame(width: 8, height: 8).opacity(pulse)
                    } else if friend.lastCallAt == nil {
                        Circle().fill(Palette.inkTertiary).frame(width: 8, height: 8)
                    }
                    Text(status).font(friend.freeNow ? .footnote.weight(.semibold) : .footnote).foregroundStyle(statusTint)
                }
            }
            Spacer(minLength: Space.xs)
            Chevron()
        }
        .padding(.vertical, 10)
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
        // Figma "Memory topic chip": lightbulb, Subheadline Emphasized, 12/6 padding, optional ✕.
        HStack(spacing: Space.xxs) {
            Image(systemName: "lightbulb.fill").font(.caption.weight(.semibold)).accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove \(title)")
            }
        }
        .foregroundStyle(Palette.butterStrong)
        .padding(.leading, Space.s)
        .padding(.trailing, onRemove == nil ? Space.s : Space.xs)
        .padding(.vertical, 6)
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

/// Figma "Toast": ink card (radius card), leading 20-pt icon, Subheadline text, optional lavender action.
public struct ToastView: View {
    let text: String
    let systemImage: String?
    let actionTitle: String?
    let action: (() -> Void)?

    public init(text: String, systemImage: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            if let systemImage {
                Image(systemName: systemImage).font(.body).foregroundStyle(Palette.bg).frame(width: 20).accessibilityHidden(true)
            }
            Text(text).font(.subheadline).foregroundStyle(Palette.bg).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.lavender)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 14)
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
                // Figma "Empty state": Title 3, Subheadline message, a 200-pt primary button.
                VStack(spacing: Space.xs) {
                    Text(title).font(Typography.title3).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                    Text(message).font(.subheadline).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
                }
                if let actionTitle, let action {
                    NudgeButton(actionTitle, kind: .primary, fullWidth: false, action: action)
                        .frame(minWidth: 200)
                        .padding(.top, Space.xs)
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
    /// Figma "Skeleton": friend row (56-pt avatar) or message row (48-pt avatar, longer second line).
    public enum Kind: Sendable { case friend, message }
    let index: Int
    let kind: Kind

    public init(index: Int = 0, kind: Kind = .friend) {
        self.index = index
        self.kind = kind
    }

    public var body: some View {
        let avatar = kind == .friend ? AvatarSize.large : AvatarSize.row
        MotionTimeline(settlesAt: 0, loops: true) { beat in
            HStack(spacing: Space.s) {
                Circle().fill(Palette.surfaceAlt).frame(width: avatar, height: avatar)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Capsule().fill(Palette.surfaceAlt).frame(width: 140, height: 14)
                    Capsule().fill(Palette.surfaceAlt).frame(width: kind == .friend ? 96 : 220, height: 12)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
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
            .frame(minHeight: 50)
            .background(Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                    .strokeBorder(Self.borderColor(state), lineWidth: Self.borderWidth(state))
            }
    }

    /// Figma "Text field": focused 2-pt lavenderStrong, error 1.5-pt roseStrong; valid shows a check, no border.
    public static func borderColor(_ state: State) -> Color {
        switch state {
        case .normal, .valid: .clear
        case .focused: Palette.lavenderStrong
        case .error: Palette.roseStrong
        }
    }

    public static func borderWidth(_ state: State) -> CGFloat {
        switch state {
        case .normal, .valid: 0
        case .focused: 2
        case .error: 1.5
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

/// 1-pt hairline between rows. `inset` is where it starts, usually under the row's text
/// (see `RowMetrics.avatarDividerInset` / `iconDividerInset`).
public struct RowDivider: View {
    let inset: CGFloat
    public init(inset: CGFloat = Space.m) { self.inset = inset }
    public var body: some View {
        Rectangle().fill(Palette.divider).frame(height: 1).padding(.leading, inset)
    }
}

/// Trailing disclosure chevron for rows that navigate.
public struct Chevron: View {
    public init() {}
    public var body: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkTertiary)
            .accessibilityHidden(true)
    }
}

/// SF Symbol on a pastel tile (settings rows, terms cards, share card).
public struct IconTile: View {
    let systemImage: String
    let tint: Palette.Tint
    let size: CGFloat

    public init(_ systemImage: String, tint: Palette.Tint, size: CGFloat = RowMetrics.iconTile) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size > 36 ? size * 0.45 : size * 0.6, weight: .medium))
            .foregroundStyle(tint.strong)
            .frame(width: size, height: size)
            .background(tint.fill, in: RoundedRectangle(cornerRadius: size > 36 ? Radius.input : Radius.chip, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// List cell: title, optional trailing value, optional chevron.
public struct ValueRow: View {
    let title: String
    let value: String?
    let chevron: Bool

    public init(_ title: String, value: String? = nil, chevron: Bool = true) {
        self.title = title
        self.value = value
        self.chevron = chevron
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            Text(title).font(.body).foregroundStyle(Palette.ink)
            Spacer(minLength: Space.xs)
            if let value, !value.isEmpty { Text(value).font(.body).foregroundStyle(Palette.inkSecondary).lineLimit(1) }
            if chevron { Chevron() }
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: RowMetrics.minHeight)
        .contentShape(Rectangle())
    }
}

/// Figma "List cell / Destructive": centered roseStrong label, full-width tap target.
public struct DestructiveRow: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title).font(.body).foregroundStyle(Palette.roseStrong)
                .frame(maxWidth: .infinity, minHeight: RowMetrics.minHeight)
                .padding(.horizontal, Space.m)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
    }
}

/// The quiet way out under a primary action ("Not now", "Skip for now").
public struct SubtleButton: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
            .frame(minHeight: 44)
            .buttonStyle(PressFeedbackButtonStyle())
    }
}

// MARK: Message bubble

extension View {
    /// Figma "Message bubble": ink text on lavender (mine) or surfaceAlt (theirs), 20-pt corners with a 6-pt
    /// tail corner on the sender's side, 14/10 padding.
    public func messageBubble(isMine: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Radius.card, bottomLeadingRadius: isMine ? Radius.card : 6,
                                           bottomTrailingRadius: isMine ? 6 : Radius.card, topTrailingRadius: Radius.card,
                                           style: .continuous)
        return self.foregroundStyle(Palette.ink)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isMine ? Palette.lavender : Palette.surfaceAlt, in: shape)
    }
}

/// Figma "Message bubble / System event": centered surfaceAlt pill with a small icon.
public struct SystemEventPill: View {
    let text: String
    let systemImage: String

    public init(_ text: String, systemImage: String = "bell.fill") {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption2).accessibilityHidden(true)
            Text(text).font(.caption)
        }
        .foregroundStyle(Palette.inkSecondary)
        .padding(.horizontal, 10).padding(.vertical, Space.xxs)
        .background(Palette.surfaceAlt, in: Capsule())
    }
}
