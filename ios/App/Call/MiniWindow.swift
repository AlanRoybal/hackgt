import Calls
import DesignSystem
import Models
import PhotoShare
import SwiftUI

/// The self-view that seamlessly becomes a shared photo (REF-7/8/9). What it shows comes from
/// `DisplayRule` via the PhotoShareController: other's photo ?? my photo ?? my camera.
struct MiniWindow: View {
    let call: CallController
    let isPreview: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var display: DisplayState { call.photos?.display ?? .selfView }

    var body: some View {
        ZStack {
            switch display {
            case .selfView:
                selfView.transition(swap)
            case .mine(let p), .other(let p):
                PhotoContent(image: p.image)
                    .transition(swap)
                    .id(p.shareId)
            }
            overlayLabel
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: Color(red: 0.12, green: 0.14, blue: 0.19).opacity(0.12), radius: 8, y: 4) // Appendix A: only shadow in the app
        .animation(Motion.resolved(Motion.photoSwap, reduceMotion: reduceMotion), value: display)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Spring cross-dissolve with a slight scale (0.96 → 1), reversed exactly on exit.
    var swap: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
    }

    @ViewBuilder var selfView: some View {
        if !call.isCameraOn {
            ZStack {
                Color(white: 0.16)
                Image(systemName: "video.slash.fill").font(.title3).foregroundStyle(Palette.callInk.opacity(0.7))
            }
        } else if isPreview {
            PreviewVideoFrame(style: .me)
        } else {
            VideoSurface(view: call.localVideoView)
        }
    }

    @ViewBuilder var overlayLabel: some View {
        if let p = display.photo {
            VStack {
                Spacer()
                VStack(spacing: 5) {
                    if p.queueLength > 1 {
                        HStack(spacing: 4) {
                            ForEach(0..<min(p.queueLength, 5), id: \.self) { i in
                                Circle().fill(i == p.queueIndex ? Color.white : Color.white.opacity(0.45)).frame(width: 5, height: 5)
                            }
                        }
                    }
                    Text(labelText).font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.bottom, 6)
            }
        }
    }

    var labelText: String {
        switch display {
        case .other: "from \(call.peerName)"
        case .mine: "you're showing"
        case .selfView: ""
        }
    }

    var accessibilityText: String {
        switch display {
        case .selfView: "Your camera"
        case .mine: "Photo you're showing to \(call.peerName)"
        case .other: "Photo from \(call.peerName)"
        }
    }
}

struct PhotoContent: View {
    let image: PhotoImage

    var body: some View {
        switch image {
        case .url(let url):
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { Color(white: 0.2) }
            }
        case .data(let data):
            if let ui = UIImage(data: data) { Image(uiImage: ui).resizable().scaledToFill() } else { Color(white: 0.2) }
        case .placeholder(let name):
            SceneryPhoto(name: name)
        }
    }
}

/// Speaker-only suggestion (Ask first): thumbnail, Show, ✕, 8-second auto-dismiss line.
struct SuggestionChip: View {
    let suggestion: PhotoSuggestion
    let isPreview: Bool
    let onShow: () -> Void
    let onDismiss: () -> Void
    @State private var progress: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Group {
                    if isPreview { SceneryPhoto(name: suggestion.query) } else {
                        AsyncImage(url: suggestion.thumbUrl) { p in
                            if let img = p.image { img.resizable().scaledToFill() } else { Palette.surfaceAlt }
                        }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show this?").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(suggestion.query).font(.caption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Palette.inkSecondary)
                        .frame(width: 32, height: 32).background(Palette.surfaceAlt, in: Circle())
                }
                .accessibilityLabel("Don't show")
                Button("Show", action: onShow)
                    .buttonStyle(NudgeButtonStyle(.primary, size: .small, fullWidth: false))
            }
            .padding(Space.xs)
            GeometryReader { g in
                Capsule().fill(Palette.lavenderStrong.opacity(0.5)).frame(width: g.size.width * progress, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, Space.s)
            .padding(.bottom, 4)
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.linear(duration: isPreview ? 0 : 8)) { progress = isPreview ? 0.62 : 0 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo suggestion: \(suggestion.query)")
    }
}

/// Automatic mode: "Showing to Mom · Hide" for 2 seconds.
struct HidePill: View {
    let name: String
    let onHide: () -> Void
    @State private var progress: CGFloat = 1

    var body: some View {
        HStack(spacing: Space.s) {
            Text("Showing to \(name)").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
            Button("Hide", action: onHide).font(.subheadline.weight(.bold)).foregroundStyle(Palette.roseStrong)
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
        .background(alignment: .leading) {
            GeometryReader { g in
                Palette.lavender.frame(width: g.size.width * progress)
            }
        }
        .background(Palette.surface)
        .clipShape(Capsule())
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.linear(duration: 2)) { progress = 0 } }
    }
}
