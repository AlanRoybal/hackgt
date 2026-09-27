import DesignSystem
import Models
import Nearby
import SwiftUI

// Tap to add (ACC-13), the NameDrop-style moment. Three beats, all coming from the top edge where the phones
// touch:
//   near:       a lavender-to-mint glow wells up from the top edge, stronger as the other phone gets closer,
//               and the app behind it leans back a little.
//   connecting: the glow blooms, a wave rolls down the screen and wipes to the app background, then soft
//               ripples keep pulsing from the top while the server confirms.
//   added:      their avatar drops in from the top (from their phone), yours rises from the bottom, and they
//               meet overlapping like the two circles in the app icon; the spark pops and a burst goes out.
// Reduce Motion turns every move into a fade.

private let tapMint = Color(light: 0x7FD1AE, dark: 0x7FD1AE)

struct TapToFriendOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let phase = app.tap.phase
        ZStack {
            switch phase {
            case .idle:
                EmptyView()
            case .near(let closeness):
                TapEdgeGlow(closeness: closeness)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            case .connecting, .added, .failed:
                TapBloom(settled: phase != .connecting)
                    .transition(.opacity)
            }
            if case .added(let user) = phase {
                TapFriendAddedCard(me: app.session.me?.user.publicUser, friend: user) {
                    app.tap.dismiss()
                } onMessage: {
                    app.tap.dismiss()
                    app.openThread(user.id)
                }
                .id(user.id)
            }
            if case .failed(let message) = phase {
                TapFailedCard(message: message) { app.tap.dismiss() }
            }
        }
        .animation(.easeOut(duration: 0.25), value: phaseKey(phase))
        .sensoryFeedback(.impact(weight: .heavy), trigger: phase == .connecting) { _, now in now }
        .sensoryFeedback(.success, trigger: phaseKey(phase)) { _, now in now == "added" }
        .sensoryFeedback(.warning, trigger: phaseKey(phase)) { _, now in now == "failed" }
    }

    private func phaseKey(_ p: NearbyTapService.Phase) -> String {
        switch p {
        case .idle: "idle"
        case .near: "near"
        case .connecting: "connecting"
        case .added: "added"
        case .failed: "failed"
        }
    }
}

extension View {
    /// The app leans back while another phone is close and during the tap, like NameDrop's squish.
    func tapToFriendLean(_ phase: NearbyTapService.Phase, reduceMotion: Bool) -> some View {
        let (scale, blur): (CGFloat, CGFloat) = switch phase {
        case .idle: (1, 0)
        case .near(let c): (1 - 0.035 * c, 0)
        case .connecting, .added, .failed: (0.92, 6)
        }
        let leaning = !reduceMotion && scale < 1
        // Shrinks like the screen behind a sheet: rounded corners on black, pulled toward the top edge.
        return self
            // A mask (not a clip) so the status bar area stays drawn when nothing's happening.
            .mask { RoundedRectangle(cornerRadius: leaning ? 44 : 0, style: .continuous).ignoresSafeArea() }
            .scaleEffect(reduceMotion ? 1 : scale, anchor: UnitPoint(x: 0.5, y: 0.2))
            .blur(radius: reduceMotion ? 0 : blur)
            .background(Color.black.ignoresSafeArea())
            .animation(Motion.resolved(Motion.snappy, reduceMotion: reduceMotion), value: scale)
    }
}

// MARK: Near

/// Light pooling at the top edge. `closeness` 0 → nothing, 1 → phones touching.
struct TapEdgeGlow: View {
    let closeness: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let c = CGFloat(closeness)
            ZStack(alignment: .top) {
                Ellipse()
                    .fill(RadialGradient(colors: [.white, Palette.lavenderStrong.opacity(0.85), tapMint.opacity(0.5), .clear],
                                         center: .top, startRadius: 0, endRadius: 80 + 220 * c))
                    .frame(width: w * (0.6 + 0.9 * c), height: 160 + 300 * c)
                    .offset(y: -70)
                    .blur(radius: 20)
                // The seam where the phones meet.
                Capsule()
                    .fill(LinearGradient(colors: [tapMint, .white, Palette.lavenderStrong], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * (0.2 + 0.6 * c), height: 4)
                    .blur(radius: 2)
                    .shadow(color: Palette.lavenderStrong, radius: 12)
            }
            .frame(width: w, alignment: .top)
            .opacity(reduceMotion ? min(1, closeness * 1.5) : min(1, 0.35 + closeness))
            .animation(.easeOut(duration: 0.15), value: closeness)
        }
        .ignoresSafeArea()
    }
}

// MARK: Bloom

/// The wave that rolls down from the top edge when the phones touch, then soft ripples while it confirms.
struct TapBloom: View {
    /// True once the result is in: the ripples stop.
    var settled: Bool
    private typealias C = Motion.Curve

    var body: some View {
        MotionTimeline(settlesAt: 1.2, loops: !settled) { beat in
            GeometryReader { geo in
                let size = geo.size
                let reach = hypot(size.width, size.height) * 2.2
                let t = beat.t
                let wave = beat.reduceMotion ? 1 : C.outCubic(C.progress(t, from: 0, to: 0.7))
                ZStack {
                    // The background the wave leaves behind.
                    Circle()
                        .fill(Palette.bg)
                        .frame(width: reach * wave, height: reach * wave)
                        .position(x: size.width / 2, y: 0)
                        .opacity(beat.reduceMotion ? C.outCubic(C.progress(t, from: 0, to: 0.2)) : 1)
                    // The bright front of the wave.
                    if !beat.reduceMotion {
                        Circle()
                            .strokeBorder(AngularGradient(colors: [Palette.lavenderStrong, tapMint, .white, Palette.lavenderStrong],
                                                          center: .center), lineWidth: 26)
                            .blur(radius: 14)
                            .frame(width: reach * wave, height: reach * wave)
                            .position(x: size.width / 2, y: 0)
                            .opacity(1 - C.progress(t, from: 0.35, to: 0.8))
                    }
                    // The source, a soft light at the top edge.
                    Ellipse()
                        .fill(RadialGradient(colors: [.white, Palette.lavenderStrong.opacity(0.7), .clear],
                                             center: .center, startRadius: 0, endRadius: 140))
                        .frame(width: 320, height: 180)
                        .position(x: size.width / 2, y: 0)
                        .blur(radius: 18)
                        .opacity(beat.reduceMotion ? 0.6 : 1 - 0.5 * C.progress(t, from: 0.3, to: 0.9))
                    if !settled && !beat.reduceMotion {
                        ForEach(0..<3, id: \.self) { i in ripple(t: t, index: i, width: size.width) }
                    }
                    if !settled {
                        VStack(spacing: Space.m) {
                            TapPhonesArt(t: 0, reduceMotion: true)
                                .frame(width: 64, height: 64)
                                .scaleEffect(1.5 * (beat.reduceMotion ? 1 : IdleMotion.breathe(t, from: 0.6, period: Motion.Period.pulse, peak: 1.06)))
                                .frame(width: 96, height: 96)
                            Text("Adding friend…")
                                .font(Typography.title).foregroundStyle(Palette.ink)
                        }
                        .position(x: size.width / 2, y: size.height * 0.45)
                        .motionLayer(beat.fadeUp(at: 0.35))
                    }
                }
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(true)
        .accessibilityElement()
        .accessibilityLabel(settled ? "" : "Adding friend")
    }

    /// Rings drifting down from the top every 1.2 s, a third of a period apart.
    private func ripple(t: Double, index: Int, width: CGFloat) -> some View {
        let period = 1.2, start = 0.6
        let local = t - start - Double(index) * period / 3
        let p = local < 0 ? 0 : local.truncatingRemainder(dividingBy: period) / period
        let d = width * (0.3 + 1.1 * p)
        return Circle()
            .strokeBorder(Palette.lavenderStrong.opacity(0.5), lineWidth: 2)
            .frame(width: d, height: d)
            .position(x: width / 2, y: 0)
            .opacity(local < 0 ? 0 : (1 - p) * 0.9)
    }
}

// MARK: Added

struct TapFriendAddedCard: View {
    let me: PublicUser?
    let friend: PublicUser
    let onDone: () -> Void
    let onMessage: () -> Void

    private typealias C = Motion.Curve
    private let avatar: CGFloat = AvatarSize.hero
    /// When the two avatars touch.
    private let meet = 0.42

    var body: some View {
        MotionTimeline(settlesAt: 1.6, loops: true) { beat in
            GeometryReader { geo in
                let t = beat.t, m = beat.reduceMotion
                let travel = geo.size.height * 0.6
                VStack(spacing: Space.l) {
                    Spacer()
                    ZStack {
                        burst(t, m)
                        HStack(spacing: -avatar * 0.28) {
                            face(me.map { AvatarView(user: $0, size: avatar) } ?? AvatarView(name: "Me", size: avatar))
                                .offset(y: m ? 0 : travel * (1 - C.spring(Motion.Springs.pop, t, from: 0.05)))
                                .offset(y: floatY(t, m, phase: 0))
                            face(AvatarView(user: friend, size: avatar))
                                .offset(y: m ? 0 : -travel * (1 - C.spring(Motion.Springs.pop, t, from: 0)))
                                .offset(y: floatY(t, m, phase: .pi))
                        }
                        .opacity(m ? C.outCubic(C.progress(t, from: 0, to: 0.2)) : 1)
                        spark(t, m)
                    }
                    .frame(height: avatar * 1.6)

                    VStack(spacing: Space.xxs) {
                        Text("You and \(friend.displayName) are friends")
                            .font(Typography.largeTitle).displayTracking()
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Palette.ink)
                            .motionLayer(beat.fadeUp(at: 0.55))
                        Text("@\(friend.handle)")
                            .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                            .motionLayer(beat.fadeUp(at: 0.63))
                    }
                    .padding(.horizontal, Space.margin)
                    Spacer()
                    VStack(spacing: Space.s) {
                        NudgeButton("Say hi", systemImage: "bubble.left.fill", action: onMessage)
                        NudgeButton("Done", kind: .secondary, action: onDone)
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.bottom, Space.l)
                    .motionLayer(beat.springUp(at: 0.8))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            // Leave it up long enough to read and tap Say hi, then get out of the way.
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { onDone() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func face(_ view: AvatarView) -> some View {
        view.overlay(Circle().strokeBorder(Palette.bg, lineWidth: 4))
            .shadow(color: Palette.lavenderStrong.opacity(0.25), radius: 16, y: 6)
    }

    private func floatY(_ t: Double, _ m: Bool, phase: Double) -> Double {
        m || t < 1.2 ? 0 : 3 * sin(2 * .pi * (t - 1.2) / Motion.Period.float + phase)
    }

    /// The spark from the app icon, popping where the circles meet.
    private func spark(_ t: Double, _ m: Bool) -> some View {
        let pop = m ? C.outCubic(C.progress(t, from: 0, to: 0.2)) : C.spring(Motion.Springs.playful, t, from: meet + 0.08)
        let breathe = m ? 1 : IdleMotion.breathe(t, from: 1.3, period: Motion.Period.pulse, peak: 1.2)
        return Circle().fill(.white)
            .frame(width: 22, height: 22)
            .shadow(color: .white, radius: 8)
            .shadow(color: Palette.lavenderStrong.opacity(0.6), radius: 14)
            .scaleEffect(pop * breathe)
            .offset(x: avatar * 0.62, y: -avatar * 0.5)
    }

    /// A ring and twelve sparks bursting from where the avatars touch.
    @ViewBuilder
    private func burst(_ t: Double, _ m: Bool) -> some View {
        if !m {
            let p = C.progress(t, from: meet, to: meet + 0.7)
            let out = C.outCubic(p)
            Circle()
                .strokeBorder(LinearGradient(colors: [Palette.lavenderStrong, tapMint], startPoint: .top, endPoint: .bottom), lineWidth: 3 * (1 - p) + 0.5)
                .frame(width: avatar * (0.6 + 2.2 * out), height: avatar * (0.6 + 2.2 * out))
                .opacity(p > 0 ? 1 - p : 0)
            ForEach(0..<12, id: \.self) { i in
                let angle = Double(i) / 12 * 2 * .pi + 0.2
                let r = avatar * (0.4 + 1.3 * out) * (i.isMultiple(of: 2) ? 1 : 0.75)
                Circle()
                    .fill(i.isMultiple(of: 3) ? tapMint : (i.isMultiple(of: 2) ? Palette.lavenderStrong : Palette.peachStrong))
                    .frame(width: i.isMultiple(of: 2) ? 8 : 6, height: i.isMultiple(of: 2) ? 8 : 6)
                    .offset(x: cos(angle) * r, y: sin(angle) * r)
                    .opacity(p > 0 ? 1 - C.inCubic(p) : 0)
            }
        }
    }
}

// MARK: Failed

struct TapFailedCard: View {
    let message: String
    let onDone: () -> Void

    var body: some View {
        MotionTimeline(settlesAt: 0.8) { beat in
            VStack(spacing: Space.m) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Palette.lavenderStrong)
                    .motionLayer(beat.pop(at: 0, from: 0.6))
                Text(message)
                    .font(Typography.title3).multilineTextAlignment(.center)
                    .foregroundStyle(Palette.ink)
                    .motionLayer(beat.fadeUp(at: 0.1))
                NudgeButton("OK", kind: .secondary, action: onDone)
                    .motionLayer(beat.springUp(at: 0.25))
            }
            .padding(.horizontal, Space.xl)
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { onDone() }
        }
    }
}

// MARK: Hint

/// Tells people about tapping (Add friends → Invite).
struct TapHintCard: View {
    var body: some View {
        MotionTimeline(settlesAt: 1, loops: true) { beat in
            HStack(spacing: Space.m) {
                TapPhonesArt(t: beat.t, reduceMotion: beat.reduceMotion)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Tap phones to add").font(Typography.friendName).foregroundStyle(Palette.ink)
                    Text("With Nudge open on both phones, hold the tops together.")
                        .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .nudgeCard()
        .accessibilityElement(children: .combine)
    }
}

/// Two phones leaning in until their tops touch, with a glow at the seam.
struct TapPhonesArt: View {
    let t: Double
    let reduceMotion: Bool

    var body: some View {
        // 0 → 1 → 0 every 2.4 s: lean in, touch, part.
        let lean = reduceMotion ? 1 : (1 - cos(2 * .pi * t / Motion.Period.breathe)) / 2
        let touch = max(0, (lean - 0.8) / 0.2)
        ZStack {
            Circle().fill(Palette.lavender)
            phone.rotationEffect(.degrees(180 - 10 * (1 - lean)), anchor: .center)
                .offset(y: -15 + 6 * (1 - lean))
            phone.offset(y: 15 - 6 * (1 - lean))
            Capsule().fill(.white).frame(width: 26 * touch, height: 3)
                .shadow(color: Palette.lavenderStrong, radius: 6 * touch)
                .shadow(color: Palette.lavenderStrong, radius: 3 * touch)
        }
        .accessibilityHidden(true)
    }

    /// Drawn for a 64-pt frame.
    private var phone: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.lavenderStrong, lineWidth: 2))
            // The island, so it reads as the tops touching.
            .overlay(alignment: .top) { Capsule().fill(Palette.lavenderStrong).frame(width: 7, height: 2.5).padding(.top, 4) }
            .frame(width: 18, height: 28)
    }
}
