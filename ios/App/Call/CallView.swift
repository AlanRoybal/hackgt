import Calls
import DesignSystem
import Models
import PhotoShare
import SwiftUI

struct CallView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlsVisible = true
    @State private var lastInteraction = Date()
    @State private var corner: SnapGeometry.Corner = .topTrailing
    @State private var drag: CGSize = .zero
    @State private var promptHeight: CGFloat = 0
    /// Drag on my own shared photo. While it's non-zero the remote video sits under the photo (and the mini window
    /// goes back to my camera), so swiping the photo away uncovers the normal call.
    @State private var photoSwipe: CGSize = .zero
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// Figma M18a: after 3 s idle the header and controls fade (0.25 s) and drift off-edge; a tap brings them back
    /// on the standard spring. Reduce Motion: fade only.
    static let autoHideAfter: Duration = .seconds(3)
    private var controlsAnimation: Animation {
        controlsVisible ? Motion.resolved(Motion.standard, reduceMotion: reduceMotion) : .easeOut(duration: Motion.Durations.chromeHide)
    }

    var call: CallController { app.call }
    var display: DisplayState { call.photos?.display ?? .selfView }
    static let miniSize = CGSize(width: 112, height: 160)

    var body: some View {
        GeometryReader { geo in
            // The mini window's snap corners keep clear of the header, the controls and any prompt stacked above them.
            let prompt = hasPrompt ? promptHeight + Space.m : 0
            let insets = EdgeInsetsLike(top: geo.safeAreaInsets.top + 56, leading: Space.m,
                                        bottom: geo.safeAreaInsets.bottom + (controlsVisible || hasPrompt ? 112 : Space.m) + prompt, trailing: Space.m)
            let full = CGSize(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ZStack(alignment: .topLeading) {
                stage
                    .ignoresSafeArea()
                    .onTapGesture { showControls() }

                topBar.padding(.top, geo.safeAreaInsets.top + Space.xs).padding(.horizontal, Space.m)

                let center = SnapGeometry.center(of: corner, container: full, window: Self.miniSize, insets: insets)
                MiniWindow(call: call, isPreview: app.isPreview, showsRemote: display.photo != nil && photoSwipe == .zero)
                    .frame(width: Self.miniSize.width, height: Self.miniSize.height)
                    .position(x: center.x + drag.width, y: center.y + drag.height)
                    .gesture(dragGesture(full: full, insets: insets))
                    .animation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion), value: corner)
                    .animation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion), value: hasPrompt)
                    .ignoresSafeArea()

                VStack(spacing: Space.m) {
                    Spacer()
                    promptLayer
                    controls
                        .opacity(controlsVisible ? 1 : 0)
                        .offset(y: controlsVisible || reduceMotion ? 0 : 12)
                        .allowsHitTesting(controlsVisible)
                        .accessibilityHidden(!controlsVisible)
                }
                .padding(.bottom, Space.l)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Palette.callScrim.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .statusBarHidden(!controlsVisible)
        .animation(controlsAnimation, value: controlsVisible)
        .task(id: lastInteraction) {
            try? await Task.sleep(for: Self.autoHideAfter)
            // Never hide while VoiceOver is on: the controls would be unreachable.
            if !Task.isCancelled, call.suggestion == nil, !voiceOver { controlsVisible = false }
        }
        .onChange(of: call.suggestion?.id) { _, id in if id != nil { showControls() } }
        .onChange(of: voiceOver) { _, on in if on { showControls() } }
        .sensoryFeedback(.impact(weight: .light), trigger: corner)
        .sensoryFeedback(.success, trigger: call.photos?.display.photo?.shareId)
    }

    // MARK: Pieces

    /// Remote video full screen, until a photo is shared: then the photo takes the stage and the
    /// remote video moves into the mini window. Both swap back when the share ends. My own photo can be
    /// swiped away like a card, uncovering the remote video underneath.
    var stage: some View {
        let lifted = photoSwipe != .zero
        return ZStack {
            if display.photo == nil || lifted {
                RemoteStage(call: call, isPreview: app.isPreview)
                    .transition(.opacity)
            }
            if let p = display.photo {
                SharedPhotoStage(photo: p, peerName: call.peerName, isMine: isMine)
                    .overlay {
                        SwipeStamp(text: "Stop showing", systemImage: "xmark", tint: Palette.roseStrong, progress: abs(photoSwipe.width) / 110)
                            .scaleEffect(1.3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: lifted ? 32 : 0, style: .continuous))
                    .scaleEffect(lifted ? 0.9 : 1)
                    .animation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion), value: lifted)
                    .tinderSwipe(offset: $photoSwipe, isEnabled: isMine) { _ in
                        call.hideMine()
                        // Cancelling swaps the display synchronously; if this photo is somehow still up, bring it back.
                        if display.photo?.shareId == p.shareId {
                            withAnimation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion)) { photoSwipe = .zero }
                        }
                    }
                    .transition(.opacity)
                    .id(p.shareId)
                    .accessibilityAction(named: "Stop showing") { if isMine { call.hideMine() } }
            }
        }
        .animation(Motion.resolved(Motion.photoSwap, reduceMotion: reduceMotion), value: display)
        .onChange(of: display.photo?.shareId) { photoSwipe = .zero }
    }

    var isMine: Bool { if case .mine = display { true } else { false } }
    var hasPrompt: Bool { display.photo != nil || call.suggestion != nil || call.autoShown != nil }

    var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(call.peerName).font(Typography.title).foregroundStyle(Palette.callInk)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.callInk.opacity(0.75))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Space.xs) {
                if call.phase == .reconnecting { Banner("Reconnecting…", style: .warning) }
                else if call.poorNetwork { Banner("Poor connection", style: .offline) }
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .offset(y: controlsVisible || reduceMotion ? 0 : -8)
        .allowsHitTesting(false)
    }

    var statusLine: String {
        switch call.phase {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        default: Formatters.clock(call.durationSec)
        }
    }

    var controls: some View {
        HStack(spacing: Space.l) {
            CallControlButton(systemImage: call.isMuted ? "mic.slash.fill" : "mic.fill", label: call.isMuted ? "Unmute" : "Mute",
                              role: call.isMuted ? .active : .normal) { call.toggleMute(); showControls() }
            CallControlButton(systemImage: call.isCameraOn ? "video.fill" : "video.slash.fill", label: call.isCameraOn ? "Turn camera off" : "Turn camera on",
                              role: call.isCameraOn ? .normal : .active) { call.toggleCamera(); showControls() }
            CallControlButton(systemImage: "arrow.triangle.2.circlepath.camera.fill", label: "Flip camera") { call.flipCamera(); showControls() }
            CallControlButton(systemImage: "phone.down.fill", label: "End call", role: .end) {
                Task { await call.leave() }
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(Palette.callScrim.opacity(0.72), in: Capsule())
    }

    /// The shared photo's label, then the Ask-first suggestion (or the Automatic-mode Hide pill), anchored above the call controls.
    var promptLayer: some View {
        VStack(spacing: Space.s) {
            // Automatic mode's Hide pill already says who it's showing to; don't repeat it.
            if let p = display.photo, call.autoShown == nil, photoSwipe == .zero {
                SharedPhotoLabel(photo: p, peerName: call.peerName, isMine: isMine) { call.hideMine() }
                    .transition(.opacity)
            }
            if let s = call.suggestion {
                SuggestionCard(suggestion: s, peerName: call.peerName, isPreview: app.isPreview,
                               onShow: { call.showSuggestion(s) }, onDismiss: { call.dismissSuggestion(s) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let a = call.autoShown {
                HidePill(name: call.peerName) { call.hideMine() }
                    .transition(.opacity)
                    .id(a.id)
            }
        }
        .frame(maxWidth: 500)
        .padding(.horizontal, Space.m)
        .animation(Motion.resolved(Motion.photoSwap, reduceMotion: reduceMotion), value: display.photo == nil)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { promptHeight = $0 }
        .animation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion), value: call.suggestion?.id)
        .animation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion), value: call.autoShown?.id)
    }

    func dragGesture(full: CGSize, insets: EdgeInsetsLike) -> some Gesture {
        DragGesture()
            .onChanged { v in drag = v.translation }
            .onEnded { v in
                let start = SnapGeometry.center(of: corner, container: full, window: Self.miniSize, insets: insets)
                let release = CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height)
                let velocity = CGVector(dx: v.velocity.width, dy: v.velocity.height)
                let target = SnapGeometry.target(release: release, velocity: velocity, container: full, window: Self.miniSize, insets: insets)
                withAnimation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion)) {
                    corner = target
                    drag = .zero
                }
            }
    }

    func showControls() {
        controlsVisible = true
        lastInteraction = Date()
    }
}

/// Remote video, or a calm placeholder when the camera is off. Full screen, or compact in the mini window.
struct RemoteStage: View {
    let call: CallController
    let isPreview: Bool
    /// Shown inside the mini window while a photo has the stage.
    var compact = false

    var body: some View {
        ZStack {
            Palette.callScrim
            if isPreview && !call.remoteCameraOff {
                PreviewVideoFrame(style: .remote)
            } else if call.hasRemoteVideo && !call.remoteCameraOff {
                VideoSurface(view: call.remoteVideoView)
            } else if let peer = call.peer {
                VStack(spacing: Space.m) {
                    AvatarView(user: peer, name: call.peerName, size: compact ? 56 : 112)
                    if !compact, call.phase == .connected || call.remoteCameraOff {
                        Label("\(call.peerName)'s camera is off", systemImage: "video.slash.fill")
                            .font(.subheadline).foregroundStyle(Palette.callInk.opacity(0.7))
                    }
                }
            }
            if call.phase == .connecting {
                Color.black.opacity(0.25)
                ProgressView().controlSize(compact ? .regular : .large).tint(Palette.callInk)
            }
        }
    }
}

struct VideoSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
