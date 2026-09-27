import AVFoundation
import Calls
import DesignSystem
import Models
import PhotoShare
import SwiftUI

/// The self-view. While a photo is being shared (REF-7/8/9) the photo takes over the full-screen stage and
/// this window shows the other caller's video instead (`showsRemote`); when the share ends both swap back.
struct MiniWindow: View {
    let call: CallController
    let isPreview: Bool
    let showsRemote: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showsRemote {
                RemoteStage(call: call, isPreview: isPreview, compact: true).transition(swap)
            } else {
                selfView.transition(swap)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: Color(red: 0.12, green: 0.14, blue: 0.19).opacity(0.12), radius: 8, y: 4) // Appendix A: only shadow in the app
        .animation(Motion.resolved(Motion.photoSwap, reduceMotion: reduceMotion), value: showsRemote)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsRemote ? "\(call.peerName)'s video" : "Your camera")
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
}

/// The shared photo, full screen: fitted so nothing is cropped, over a blurred fill of itself.
/// A shared video plays once, muted, over its poster frame (VID-4).
/// A top scrim keeps the call header readable over bright photos.
struct SharedPhotoStage: View {
    let photo: PhotoRef
    let peerName: String
    let isMine: Bool

    var body: some View {
        ZStack(alignment: .top) {
            PhotoContent(image: photo.image)
                .blur(radius: 40)
                .overlay(Color.black.opacity(0.35))
                .accessibilityHidden(true)
            Group {
                if case .video(let url, _) = photo.image {
                    ZStack {
                        PhotoContent(image: photo.image, contentMode: .fit)
                        ClipPlayer(url: url)
                    }
                } else {
                    PhotoContent(image: photo.image, contentMode: .fit)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .allowsHitTesting(false)
        }
    }

    var label: String {
        let kind = photo.image.isVideo ? "Video" : "Photo"
        return isMine ? "\(kind) you're showing to \(peerName)" : "\(kind) from \(peerName)"
    }
}

/// Plays a short clip once, muted, with no controls. Muted because the call's echo canceller doesn't hear
/// app playback, so the clip's sound would reach the other phone twice through the mic (D-311).
struct ClipPlayer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause // hold the last frame until the stage dissolves
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// A shared video's exit: it blurs, swells slightly and fades, rather than cutting back to the call.
struct Dissipate: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: 28 * amount)
            .scaleEffect(1 + 0.06 * amount)
            .opacity(1 - amount)
    }
}

extension AnyTransition {
    static func sharedStage(isVideo: Bool, reduceMotion: Bool) -> AnyTransition {
        guard isVideo, !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .opacity,
                           removal: .modifier(active: Dissipate(amount: 1), identity: Dissipate(amount: 0)))
    }
}

/// Who a shared photo is from or to, its place in the queue, and (for my own photo) a way to stop it.
struct SharedPhotoLabel: View {
    let photo: PhotoRef
    let peerName: String
    let isMine: Bool
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            if photo.image.isVideo {
                Image(systemName: "play.rectangle.fill").font(.subheadline).foregroundStyle(.white).accessibilityHidden(true)
            }
            if photo.queueLength > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<min(photo.queueLength, 5), id: \.self) { i in
                        Circle().fill(i == photo.queueIndex ? Color.white : Color.white.opacity(0.45)).frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
            }
            Text(isMine ? "Showing to \(peerName)" : "from \(peerName)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            if isMine {
                Button(action: onHide) {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Color.white.opacity(0.2), in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .padding(.vertical, -8).padding(.trailing, -10)
                .accessibilityLabel(photo.image.isVideo ? "Stop showing video" : "Stop showing photo")
            }
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

struct PhotoContent: View {
    let image: PhotoImage
    var contentMode: ContentMode = .fill

    var body: some View {
        // Filling reports a size larger than the proposal; hosting it in an overlay on a flexible
        // Color keeps the mini window's layout at its fixed frame, then clipped() trims the overflow.
        Color.clear
            .overlay { content }
            .clipped()
    }

    @ViewBuilder private var content: some View {
        switch image {
        case .url(let url):
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().aspectRatio(contentMode: contentMode) } else { Color(white: 0.2) }
            }
        case .data(let data):
            if let ui = UIImage(data: data) { Image(uiImage: ui).resizable().aspectRatio(contentMode: contentMode) } else { Color(white: 0.2) }
        case .placeholder(let name):
            if contentMode == .fit { SceneryPhoto(name: name).aspectRatio(3 / 4, contentMode: .fit) } else { SceneryPhoto(name: name) }
        case .video(_, let poster):
            // The poster frame; `ClipPlayer` draws the moving picture over it.
            if let poster { PhotoContent(image: .url(poster), contentMode: contentMode) } else { Color.black }
        }
    }
}

/// Speaker-only suggestion (Ask first): a large thumbnail with full-size Show / Not now buttons and an
/// 8-second auto-dismiss line. Sized to be easy to read and hit mid-conversation. Swipe right to show,
/// left to dismiss.
struct SuggestionCard: View {
    let suggestion: PhotoSuggestion
    let peerName: String
    let isPreview: Bool
    let onShow: () -> Void
    let onDismiss: () -> Void
    @State private var progress: CGFloat = 1
    @State private var swipe: CGSize = .zero
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        card
            .overlay(alignment: .topLeading) {
                SwipeStamp(text: "Show", systemImage: "photo.fill", tint: Palette.lavenderStrong, progress: swipe.width / 90)
                    .rotationEffect(.degrees(-8)).padding(Space.s)
            }
            .overlay(alignment: .topTrailing) {
                SwipeStamp(text: "Not now", systemImage: "xmark", tint: Palette.inkSecondary, progress: -swipe.width / 90)
                    .rotationEffect(.degrees(8)).padding(Space.s)
            }
            .tinderSwipe(offset: $swipe) { $0 == .right ? onShow() : onDismiss() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(suggestion.isVideo ? "Video" : "Photo") suggestion: \(suggestion.query)")
    }

    var card: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Group {
                    if isPreview { SceneryPhoto(name: suggestion.query) } else {
                        AsyncImage(url: suggestion.thumbUrl) { p in
                            if let img = p.image { img.resizable().scaledToFill() } else { Palette.surfaceAlt }
                        }
                    }
                }
                .frame(width: 88, height: 88)
                .overlay(alignment: .bottomLeading) { if suggestion.isVideo { VideoBadge(durationMs: suggestion.durationMs).padding(Space.xxs) } }
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(suggestion.isVideo ? "Show this video to \(peerName)?" : "Show this to \(peerName)?")
                        .font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(suggestion.query).font(.subheadline).foregroundStyle(Palette.inkSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            let buttons = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Space.s)) : AnyLayout(HStackLayout(spacing: Space.s))
            buttons {
                Button("Not now", action: onDismiss)
                    .buttonStyle(NudgeButtonStyle(.secondary))
                Button(action: onShow) { Label(suggestion.isVideo ? "Play" : "Show", systemImage: suggestion.isVideo ? "play.fill" : "photo.fill") }
                    .buttonStyle(NudgeButtonStyle(.primary))
            }
            GeometryReader { g in
                Capsule().fill(Palette.lavenderStrong.opacity(0.5)).frame(width: g.size.width * progress, height: 3)
            }
            .frame(height: 3)
        }
        .padding(Space.m)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.linear(duration: isPreview ? 0 : 8)) { progress = isPreview ? 0.62 : 0 } }
    }
}

/// A play glyph and the clip's length, over a video's thumbnail.
struct VideoBadge: View {
    let durationMs: Int?

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "play.fill")
            if let durationMs { Text(Self.format(durationMs)).monospacedDigit() }
        }
        .font(.caption2.weight(.bold)).foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityHidden(true)
    }

    static func format(_ ms: Int) -> String {
        let s = max(1, Int((Double(ms) / 1000).rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
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
