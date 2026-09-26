import AuthenticationServices
import DesignSystem
import SwiftUI

struct WelcomeFlow: View {
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            WelcomeView { showSignIn = true }
                .navigationDestination(isPresented: $showSignIn) { SignInView() }
        }
    }
}

/// Welcome 1–3 (Figma M02a–c). Expressive tier: a choreographed entrance, a slow idle sway/float, and a
/// page stretch between cards, all driven by one clock (see `ExpressiveEntrance`, `IdleMotion`, `PageStretch`).
/// Reduce Motion: everything cross-fades in over 0.2 s, pages cross-fade, no idle loop.
struct WelcomeView: View {
    var onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.motionSnapshot) private var snapshot
    @State private var clock = MotionClock()
    @State private var page = 0
    @State private var change: PageChange?
    @State private var isVisible = false
    /// Reduce Motion only: the fades are done, so the clock can stop.
    @State private var settled = false
    @GestureState private var isDragging = false

    struct Card {
        let art: WelcomeArt.Kind
        let title: String
        let body: String
        let showsSkip: Bool
    }

    struct PageChange: Equatable {
        let from: Int
        let to: Int
        /// Clock time the change began.
        let start: TimeInterval
    }

    static let cards = [
        Card(art: .calendar, title: "Know when you’re both free",
             body: "Nudge looks for moments when you and a friend are both free. Only busy times, never event names.",
             showsSkip: true),
        Card(art: .call, title: "Call in one tap",
             body: "You both get a nudge. If you both accept, a video call starts.",
             showsSkip: true),
        Card(art: .photos, title: "Your photos join the conversation, and we remember what matters",
             body: "Mention the beach trip and the photo appears. Afterward, we help you follow up.",
             showsSkip: false),
    ]

    private var cards: [Card] { Self.cards }

    /// Idle clocks pause while the user touches, and when the screen isn't showing or the app is in the background.
    private var paused: Bool {
        if !isVisible || scenePhase == .background { return true }
        return reduceMotion ? settled : isDragging
    }

    var body: some View {
        TimelineView(.animation(paused: paused || snapshot)) { context in
            WelcomeFrame(t: snapshot ? ExpressiveEntrance.settled : clock.time(at: context.date), page: page, change: change,
                         reduceMotion: reduceMotion, onNext: advance, onSkip: onContinue)
        }
        .nudgeBackground()
        .toolbar(.hidden, for: .navigationBar)
        .contentShape(Rectangle())
        .simultaneousGesture(swipe)
        .onAppear {
            isVisible = true
            if clock.time(at: .now) == 0 { clock = MotionClock(startedAt: .now) }
        }
        .onDisappear { isVisible = false }
        .onChange(of: paused) { _, paused in clock.setRunning(!paused, at: .now) }
        .task(id: [change?.start ?? 0, reduceMotion ? 1 : 0]) {
            // Reduce Motion has no idle loop: stop the clock once the entrance or cross-fade finishes.
            settled = false
            guard reduceMotion else { return }
            let busyUntil = max(Motion.Durations.fade, (change?.start ?? 0) + PageStretch.duration(reduceMotion: true))
            try? await Task.sleep(for: .seconds(max(busyUntil - clock.time(at: .now), 0) + 0.05))
            if !Task.isCancelled { settled = true }
        }
    }

    private func advance() {
        if page == cards.count - 1 { onContinue() } else { go(to: page + 1) }
    }

    private func go(to target: Int) {
        guard cards.indices.contains(target), target != page else { return }
        // Interruptible: a tap mid-transition starts the next change from the current target.
        change = PageChange(from: page, to: target, start: clock.time(at: .now))
        page = target
        AccessibilityNotification.Announcement(cards[target].title).post()
    }

    /// Swipes change pages with the same stretch. Content doesn't track the finger (nothing animates during a drag).
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                guard abs(value.translation.width) > abs(value.translation.height), abs(predicted) > 60 else { return }
                go(to: page + (predicted < 0 ? 1 : -1))
            }
    }
}

/// One frame of the Welcome choreography at clock time `t`.
/// Figma layout: 44 pt top bar, flexible space, 300 × 225 art, 32, title, 12, body, flexible space, dots, 24, button.
private struct WelcomeFrame: View {
    let t: Double
    let page: Int
    let change: WelcomeView.PageChange?
    let reduceMotion: Bool
    let onNext: () -> Void
    let onSkip: () -> Void

    private var cards: [WelcomeView.Card] { WelcomeView.cards }
    /// Seconds into the current page change, while it's running.
    private var dt: Double? {
        guard let change, t - change.start < PageStretch.duration(reduceMotion: reduceMotion) else { return nil }
        return t - change.start
    }
    private var from: Int { dt == nil ? page : change!.from }
    /// The copy and button label switch pages partway through the change.
    private var copyPage: Int { dt.map { $0 < PageStretch.copySwap(reduceMotion: reduceMotion) } == true ? from : page }
    private var idle: Bool { !reduceMotion && t > ExpressiveEntrance.settled }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            FitOrScroll {
                VStack(spacing: 0) {
                    Spacer(minLength: Space.l)
                    art
                    Spacer().frame(height: Space.xl)
                    copy
                    Spacer(minLength: Space.l)
                }
                .padding(.horizontal, Space.margin)
            }
            PageDots(count: cards.count, page: page, from: from, dt: dt, reduceMotion: reduceMotion,
                     pop: ExpressiveEntrance.activeDotScale(t, reduceMotion: reduceMotion))
                .motionLayer(ExpressiveEntrance.pageControl(t, reduceMotion: reduceMotion))
                .padding(.bottom, Space.l)
            NudgeButton(copyPage == cards.count - 1 ? "Get started" : "Continue", action: onNext)
                .motionLayer(ExpressiveEntrance.primaryAction(t, reduceMotion: reduceMotion).tappable)
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.m)
        }
    }

    // MARK: Skip

    private var topBar: some View {
        let shows = cards[page].showsSkip
        let visibility: Double = switch (cards[from].showsSkip, shows, dt) {
        case (_, _, nil): shows ? 1 : 0
        case (true, true, _): 1
        case (false, false, _): 0
        case (true, false, let dt?): PageStretch.outgoingCopy(dt, reduceMotion: reduceMotion).opacity
        case (false, true, let dt?): PageStretch.incomingTitle(dt, reduceMotion: reduceMotion).opacity
        }
        let opacity = ExpressiveEntrance.secondaryAction(t, reduceMotion: reduceMotion).opacity * visibility
        return HStack {
            Spacer()
            if shows || visibility > 0 {
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.body)
                        .foregroundStyle(Palette.lavenderStrong)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(PressFeedbackButtonStyle())
                    .opacity(shows ? max(opacity, MotionLayer.tappableOpacity) : opacity)
                    .disabled(!shows)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, Space.margin - Space.xs)
    }

    // MARK: Art

    private var art: some View {
        ZStack {
            if let dt {
                artLayer(cards[from].art).motionLayer(PageStretch.outgoingArt(dt, reduceMotion: reduceMotion))
                artLayer(cards[page].art).motionLayer(PageStretch.incomingArt(dt, reduceMotion: reduceMotion))
            } else {
                artLayer(cards[page].art)
            }
        }
        .frame(width: WelcomeArt.size.width, height: WelcomeArt.size.height)
        .offset(y: idle ? IdleMotion.floatY(t) : 0)
        .motionLayer(ExpressiveEntrance.art(t, reduceMotion: reduceMotion))
    }

    private func artLayer(_ kind: WelcomeArt.Kind) -> some View {
        ZStack {
            WelcomeArt.Backdrop(kind: kind)
                .scaleEffect(ExpressiveEntrance.backdropScale(t, reduceMotion: reduceMotion)
                    * (idle ? IdleMotion.backdropBreathe(t) : 1))
                .rotationEffect(idle ? IdleMotion.backdropAngle(t) : .zero)
            WelcomeArt(kind: kind)
                .rotationEffect(idle ? IdleMotion.artAngle(t) : .zero)
        }
    }

    // MARK: Copy

    private var copy: some View {
        let incoming = dt != nil && copyPage == page
        let title = dt.map { incoming ? PageStretch.incomingTitle($0, reduceMotion: reduceMotion)
            : PageStretch.outgoingCopy($0, reduceMotion: reduceMotion) } ?? .rest
        let body = dt.map { incoming ? PageStretch.incomingBody($0, reduceMotion: reduceMotion)
            : PageStretch.outgoingCopy($0, reduceMotion: reduceMotion) } ?? .rest

        return ZStack(alignment: .top) {
            // Reserve the tallest card's copy so the art doesn't jump when the copy swaps mid-stretch.
            ForEach(cards.indices, id: \.self) { i in
                CopyBlock(card: cards[i], titleLayer: .rest, bodyLayer: .rest).hidden()
            }
            CopyBlock(card: cards[copyPage],
                      titleLayer: title.combined(with: ExpressiveEntrance.title(t, reduceMotion: reduceMotion)),
                      bodyLayer: body.combined(with: ExpressiveEntrance.body(t, reduceMotion: reduceMotion)))
        }
        .frame(maxWidth: .infinity)
    }

    private struct CopyBlock: View {
        let card: WelcomeView.Card
        let titleLayer: MotionLayer
        let bodyLayer: MotionLayer

        var body: some View {
            VStack(spacing: Space.s) {
                Text(card.title)
                    .font(Typography.largeTitle).displayTracking()
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .motionLayer(titleLayer)
                Text(card.body)
                    .font(.body)
                    .foregroundStyle(Palette.inkSecondary)
                    .motionLayer(bodyLayer)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Figma page control: 8 pt dots, 8 pt apart. The active ink dot pops in, then slides between positions.
private struct PageDots: View {
    let count: Int
    let page: Int
    let from: Int
    let dt: Double?
    let reduceMotion: Bool
    let pop: Double

    private static let step: CGFloat = 16

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: Space.xs) {
                ForEach(0..<count, id: \.self) { _ in dot(Palette.divider) }
            }
            if let dt {
                if reduceMotion {
                    let fade = PageStretch.crossfade(dt)
                    dot(Palette.ink).offset(x: CGFloat(from) * Self.step).opacity(1 - fade)
                    dot(Palette.ink).offset(x: CGFloat(page) * Self.step).opacity(fade)
                } else {
                    let x = Double(from) + Double(page - from) * PageStretch.dotTravel(dt, reduceMotion: false)
                    dot(Palette.ink)
                        .scaleEffect(x: PageStretch.dotStretch(dt, reduceMotion: false), y: 1)
                        .offset(x: x * Self.step)
                }
            } else {
                dot(Palette.ink).scaleEffect(pop).offset(x: CGFloat(page) * Self.step)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(count)")
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

private extension MotionLayer {
    /// Both layers applied together (a page change on top of the entrance).
    func combined(with other: MotionLayer) -> MotionLayer {
        MotionLayer(opacity: opacity * other.opacity, offsetY: offsetY + other.offsetY,
                    scale: scale * other.scale, scaleY: scaleY * other.scaleY)
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var devName = ""
    @State private var working = false

    private typealias C = Motion.Curve

    /// Figma M03: the icon pops 50 → 100%, the copy staggers up, the Apple button springs up last.
    /// Idle: the icon floats 4 pt (3.2 s) and the spark breathes to 130% (1.6 s).
    var body: some View {
        MotionTimeline(loops: true) { beat in content(beat) }
            .nudgeBackground()
            .navigationBarBackButtonHidden(false)
    }

    private func content(_ beat: Beat) -> some View {
        let t = beat.t, idle = beat.idle(after: ExpressiveEntrance.settled)
        return VStack(spacing: Space.l) {
            Spacer()
            AppIconMark(size: 88,
                        spark: idle ? IdleMotion.breathe(t, from: ExpressiveEntrance.settled, period: Motion.Period.pulse, peak: 1.3) : 1)
                .offset(y: idle ? IdleMotion.floatOffset(t, from: ExpressiveEntrance.settled, period: 3.2, upFirst: true) : 0)
                .motionLayer(beat.reduceMotion ? beat.fadeIn(at: 0) : MotionLayer(
                    opacity: C.outCubic(C.progress(t, from: 0, to: 0.2)),
                    scale: 0.5 + 0.5 * C.spring(Motion.Springs.playful, t, from: 0)))
            VStack(spacing: Space.s) {
                Text("Stay close to your people").font(Typography.largeTitle).displayTracking()
                    .foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                    .motionLayer(beat.fadeUp(at: 0.3))
                Text("Sign in to find the moments you and your friends are both free.")
                    .font(.body).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
                    .motionLayer(beat.fadeUp(at: 0.4))
            }
            .padding(.horizontal, Space.l)
            Spacer()

            VStack(spacing: Space.s) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    guard case .success(let auth) = result,
                          let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                          let tokenData = cred.identityToken else {
                        if case .failure(let e) = result, (e as? ASAuthorizationError)?.code != .canceled {
                            app.session.error = "Sign in didn't complete. Try again."
                        }
                        return
                    }
                    let name = cred.fullName.flatMap { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                    Task {
                        working = true
                        await app.session.signInWithApple(identityToken: String(decoding: tokenData, as: UTF8.self), fullName: name?.nonEmptyString)
                        working = false
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Radius.input + 2, style: .continuous))
                .disabled(working)
                .motionLayer(beat.springUp(at: 0.6).tappable)

                if let error = app.session.error {
                    Text(error).font(.footnote).foregroundStyle(Palette.roseStrong).multilineTextAlignment(.center)
                }

                Group {
                    #if DEBUG
                    DevSignIn(name: $devName, working: $working)
                    #endif

                    Text("By continuing you'll be asked to review our Terms.")
                        .font(.footnote).foregroundStyle(Palette.inkTertiary).multilineTextAlignment(.center)
                        .padding(.top, Space.xs)
                }
                .motionLayer(beat.fadeIn(at: 0.85, for: 0.18).tappable)
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, Space.m)
        }
    }
}

#if DEBUG
/// DEBUG-only: sign in as a dev-stage test user (POST /auth/dev) so the simulator can reach the backend.
private struct DevSignIn: View {
    @Environment(AppModel.self) private var app
    @Binding var name: String
    @Binding var working: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Developer sign-in").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
            HStack(spacing: Space.xs) {
                TextField("test username", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(NudgeTextFieldStyle())
                NudgeButton("Go", kind: .secondary, size: .medium, fullWidth: false, isLoading: working) {
                    Task {
                        working = true
                        await app.session.devSignIn(username: name)
                        working = false
                    }
                }
                .disabled(name.count < 3)
            }
        }
        .padding(Space.s)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
#endif

extension String {
    var nonEmptyString: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
