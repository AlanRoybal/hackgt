import DesignSystem
import Models
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
        .animation(Motion.resolved(Motion.move, reduceMotion: reduceMotion), value: route)
        .onChange(of: route) { _, r in
            if r == .main || r == .setup { Task { await app.didSignIn() } }
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            BrandMark(size: 72)
        }
    }
}

/// The two-circle mark from the app icon.
struct BrandMark: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Palette.lavender).frame(width: size, height: size).offset(x: -size * 0.3)
            Circle().fill(Palette.peach).frame(width: size, height: size).offset(x: size * 0.3)
            Circle().fill(Palette.mintStrong).frame(width: size, height: size).offset(x: size * 0.3)
                .mask(Circle().frame(width: size, height: size).offset(x: -size * 0.3))
        }
        .frame(width: size * 1.6, height: size)
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
        .fullScreenCover(isPresented: flowPresented) { FlowContainer() }
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
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
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
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(5))
                    if app.nudges.toast?.id == toast.id { app.nudges.toast = nil }
                }
            }
        }
        .animation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion), value: app.nudges.toast?.id)
    }
}
