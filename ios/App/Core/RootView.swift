import DesignSystem
import Models
import Nudges
import SwiftUI

/// Auth → ToS → Handle → Setup → Tabs (SPEC §4.2).
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Route: Hashable { case launching, welcome, terms, handle, setup, main }

    var route: Route {
        switch app.session.status {
        case .loading: return .launching
        case .signedOut: return .welcome
        case .signedIn:
            guard let me = app.session.me else { return .launching }
            if me.needsTos { return .terms }
            if me.needsHandle { return .handle }
            return app.onboardingComplete ? .main : .setup
        }
    }

    var body: some View {
        ZStack {
            switch route {
            case .launching: LaunchView()
            case .welcome: WelcomeFlow()
            case .terms: TermsView()
            case .handle: HandleView()
            case .setup: SetupFlow()
            case .main: MainView()
            }
        }
        .transition(.opacity)
        // Screen hand-offs (Launch → Welcome, etc.) are a 0.2 s cross-fade.
        .animation(Motion.fade, value: route)
        .onChange(of: route) { _, r in
            if r == .main || r == .setup { Task { await app.didSignIn() } }
        }
    }
}

/// Figma M01: the icon grows 25 → 100% (playful spring) while untilting 14°, its two circles lean together
/// (pop spring from 0.25 s), the spark pops at 0.6 s then breathes, and the wordmark fades up at 0.45 s.
struct LaunchView: View {
    private typealias C = Motion.Curve

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            MotionTimeline(settlesAt: 1.1, loops: true) { beat in
                let t = beat.t, m = beat.reduceMotion
                VStack(spacing: Space.m) {
                    AppIconMark(size: 96,
                                spread: m ? 0 : 12 * (1 - C.spring(Motion.Springs.pop, t, from: 0.25)),
                                spark: m ? 1 : C.spring(Motion.Springs.playful, t, from: 0.6)
                                    * IdleMotion.breathe(t, from: 1.1, period: Motion.Period.pulse, peak: 1.25))
                        .rotationEffect(.degrees(m ? 0 : 14 * (1 - C.spring(Motion.Springs.settle, t, from: 0))))
                        .motionLayer(m ? beat.fadeIn(at: 0) : MotionLayer(
                            opacity: C.outCubic(C.progress(t, from: 0, to: 0.2)),
                            scale: 0.25 + 0.75 * C.spring(Motion.Springs.playful, t, from: 0)))
                    Text("Nudge")
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold)).tracking(-0.6)
                        .foregroundStyle(Palette.ink)
                        .motionLayer(beat.fadeUp(at: 0.45))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Nudge")
    }
}

/// The app icon (Figma "App icon"): lavender tile, two overlapping circles and a white spark. `spread` pushes the
/// circles apart and `spark` scales the spark, so launch and sign-in can animate the parts.
struct AppIconMark: View {
    var size: CGFloat
    var spread: CGFloat = 0
    var spark: CGFloat = 1

    var body: some View {
        let k = size / 96
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 21.6 * k, style: .continuous).fill(Palette.lavender)
            Circle().fill(Palette.lavenderStrong).frame(width: 40 * k, height: 40 * k)
                .offset(x: (17.6 - spread) * k, y: 30.4 * k)
            Circle().fill(Color(light: 0x7FD1AE, dark: 0x7FD1AE).opacity(0.92)).frame(width: 40 * k, height: 40 * k)
                .offset(x: (40 + spread) * k, y: 24 * k)
            Circle().fill(.white).frame(width: 9.6 * k, height: 9.6 * k)
                .scaleEffect(spark)
                .offset(x: 65.6 * k, y: 17.6 * k)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 21.6 * k, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Friends", systemImage: "person.2.fill", value: AppModel.Tab.friends) {
                FriendsView()
            }
            Tab("Messages", systemImage: "bubble.left.and.bubble.right.fill", value: AppModel.Tab.messages) {
                ConversationsView()
            }
            .badge(app.messages.unreadTotal)
            Tab("Settings", systemImage: "gearshape.fill", value: AppModel.Tab.settings) {
                SettingsView()
            }
        }
        .overlay(alignment: .top) { NudgeBannerOverlay() }
        .overlay(alignment: .bottom) { ToastOverlay() }
        .sheet(item: followUpBinding) { FollowUpApprovalSheet(draft: $0) }
        .fullScreenCover(isPresented: flowPresented) { FlowContainer() }
    }

    /// Swiping the sheet away leaves the draft unsent; the notification stays so it can still be approved later.
    private var followUpBinding: Binding<FollowUpDraft?> {
        Binding(get: { app.nudges.followUp }, set: { if $0 == nil { app.nudges.dismissFollowUp() } })
    }

    private var flowPresented: Binding<Bool> {
        Binding(get: { FlowContainer.current(app) != nil }, set: { _ in })
    }
}

/// One full-screen cover for waiting room → call → summary so transitions don't stack modals.
struct FlowContainer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Flow: Hashable { case waiting, incoming, call, summary }

    static func current(_ app: AppModel) -> Flow? {
        if app.call.phase == .connecting || app.call.phase == .connected || app.call.phase == .reconnecting { return .call }
        if app.memory.pendingSummary != nil { return .summary }
        if app.incoming != nil { return .incoming }
        if app.nudges.waiting != nil { return .waiting }
        return nil
    }

    var body: some View {
        ZStack {
            switch Self.current(app) {
            case .call: CallView().transition(.opacity)
            case .summary: CallSummaryView().transition(.move(edge: .bottom).combined(with: .opacity))
            case .incoming: IncomingCallView().transition(.opacity)
            case .waiting: WaitingRoomView().transition(.opacity)
            case nil: Palette.bg.ignoresSafeArea()
            }
        }
        .animation(Motion.resolved(Motion.move, reduceMotion: reduceMotion), value: Self.current(app))
    }
}

struct NudgeBannerOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let nudge = app.nudges.banner {
                NudgeBanner(nudge: nudge, me: app.session.me?.user.publicUser)
                    .padding(.horizontal, Space.s)
                    // Drops in on the standard spring; leaves up and out with a 0.3 s ease-in.
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity).animation(.easeIn(duration: Motion.Durations.banner))))
                    .zIndex(1)
            }
        }
        .animation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion), value: app.nudges.banner?.id)
    }
}

struct ToastOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = app.nudges.toast {
                ToastView(text: toast.text, actionTitle: toast.actionTitle) {
                    Task { await app.nudges.undoLess() }
                }
                .padding(.bottom, 88)
                // Figma M15c: rises 24 pt on the standard spring, holds 4 s, fades out over 0.2 s.
                .transition(.asymmetric(
                    insertion: reduceMotion ? .opacity : .offset(y: 24).combined(with: .opacity),
                    removal: .opacity.animation(.easeOut(duration: Motion.Durations.fade))))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if app.nudges.toast?.id == toast.id { app.nudges.toast = nil }
                }
            }
        }
        .animation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion), value: app.nudges.toast?.id)
    }
}
