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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// Figma M18a: after 3 s idle the header and controls fade (0.25 s) and drift off-edge; a tap brings them back
    /// on the standard spring. Reduce Motion: fade only.
    static let autoHideAfter: Duration = .seconds(3)
    private var controlsAnimation: Animation {
        controlsVisible ? Motion.resolved(Motion.standard, reduceMotion: reduceMotion) : .easeOut(duration: Motion.Durations.chromeHide)
    }

    var call: CallController { app.call }
    static let miniSize = CGSize(width: 112, height: 160)

    var body: some View {
        GeometryReader { geo in
            let insets = EdgeInsetsLike(top: geo.safeAreaInsets.top + 56, leading: Space.m,
                                        bottom: geo.safeAreaInsets.bottom + (controlsVisible ? 112 : Space.m), trailing: Space.m)
            let full = CGSize(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ZStack(alignment: .topLeading) {
                RemoteStage(call: call, isPreview: app.isPreview)
                    .ignoresSafeArea()
                    .onTapGesture { showControls() }

                topBar.padding(.top, geo.safeAreaInsets.top + Space.xs).padding(.horizontal, Space.m)

                let center = SnapGeometry.center(of: corner, container: full, window: Self.miniSize, insets: insets)
                MiniWindow(call: call, isPreview: app.isPreview)
                    .frame(width: Self.miniSize.width, height: Self.miniSize.height)
                    .position(x: center.x + drag.width, y: center.y + drag.height)
                    .gesture(dragGesture(full: full, insets: insets))
                    .animation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion), value: corner)
                    .ignoresSafeArea()

                suggestionLayer(center: center, full: full)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
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
        .onChange(of: voiceOver) { _, on in if on { showControls() } }
        .sensoryFeedback(.impact(weight: .light), trigger: corner)
        .sensoryFeedback(.success, trigger: call.photos?.display.photo?.shareId)
    }

    // MARK: Pieces

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

    @ViewBuilder
    func suggestionLayer(center: CGPoint, full: CGSize) -> some View {
        let below = corner == .topLeading || corner == .topTrailing
        let leading = corner == .topLeading || corner == .bottomLeading
        let chipWidth = typeSize.isAccessibilitySize ? full.width - Space.m * 2 : min(320, full.width - Space.m * 2)
        let offset: CGFloat = typeSize.isAccessibilitySize ? 110 : 46
        let y = center.y + (below ? Self.miniSize.height / 2 + offset : -Self.miniSize.height / 2 - offset)
        let x = leading ? Space.m + chipWidth / 2 : full.width - Space.m - chipWidth / 2
        ZStack {
            if let s = call.suggestion {
                SuggestionChip(suggestion: s, isPreview: app.isPreview,
                               onShow: { call.showSuggestion(s) }, onDismiss: { call.dismissSuggestion(s) })
                    .transition(.scale(scale: 0.9, anchor: below ? .top : .bottom).combined(with: .opacity))
            } else if let a = call.autoShown {
                HidePill(name: call.peerName) { call.hideMine() }
                    .transition(.opacity)
                    .id(a.id)
            }
        }
        .frame(width: chipWidth)
        .position(x: x, y: y)
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
                let projected = CGPoint(x: release.x + SnapGeometry.project(velocity.dx), y: release.y + SnapGeometry.project(velocity.dy))
                // Flinging my own photo off-screen ends it early (REF-9 swipe → cancel).
                if case .mine = call.photos?.display, projected.x < -40 || projected.x > full.width + 40 {
                    call.hideMine()
                }
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

/// Full-screen remote video, or a calm placeholder when the camera is off.
struct RemoteStage: View {
    let call: CallController
    let isPreview: Bool

    var body: some View {
        ZStack {
            Palette.callScrim
            if isPreview && !call.remoteCameraOff {
                PreviewVideoFrame(style: .remote)
            } else if call.hasRemoteVideo && !call.remoteCameraOff {
                VideoSurface(view: call.remoteVideoView)
            } else if let peer = call.peer {
                VStack(spacing: Space.m) {
                    AvatarView(user: peer, name: call.peerName, size: 112)
                    if call.phase == .connected || call.remoteCameraOff {
                        Label("\(call.peerName)'s camera is off", systemImage: "video.slash.fill")
                            .font(.subheadline).foregroundStyle(Palette.callInk.opacity(0.7))
                    }
                }
            }
            if call.phase == .connecting {
                Color.black.opacity(0.25)
                ProgressView().controlSize(.large).tint(Palette.callInk)
            }
        }
    }
}

struct VideoSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
