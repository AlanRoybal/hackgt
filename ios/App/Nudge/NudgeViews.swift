import DesignSystem
import Models
import Nudges
import SwiftUI

/// In-app drop-down nudge (NUD-9): springs in, swipe up to dismiss, long-press for "See this less often".
struct NudgeBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let nudge: Nudge
    let me: PublicUser?
    @State private var dragY: CGFloat = 0
    @State private var accepted = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.s) {
                // Figma M15a: the two avatars nudge together 8 pt (pop spring) as the banner lands.
                MotionTimeline(settlesAt: 1) { beat in
                    AvatarPair(me: me, friend: nudge.friend, friendName: nudge.friendName, size: 40,
                               spread: beat.reduceMotion ? 0 : 8 * (1 - Motion.Curve.spring(Motion.Springs.pop, beat.t, from: 0.2)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(nudge.title).font(.headline).foregroundStyle(Palette.ink).lineLimit(2)
                    Text(windowLine).font(.footnote.weight(.medium)).foregroundStyle(Palette.mintStrong)
                }
                Spacer(minLength: 0)
            }
            Text(nudge.body).font(.subheadline).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            let buttons = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Space.xs)) : AnyLayout(HStackLayout(spacing: Space.xs))
            buttons {
                NudgeButton("Skip", kind: .skip, size: .medium) { Task { await app.nudges.skip(nudge) } }
                NudgeButton("Accept", systemImage: "video.fill", kind: .accept, size: .medium) {
                    accepted = true
                    Task { await app.nudges.accept(nudge) }
                }
            }
            if nudge.kind == .auto {
                Button("Not now · pause for an hour") { Task { await app.nudges.pause(nudge) } }
                    .font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(Space.m)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.divider, lineWidth: 1))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contextMenu {
            Button("Pause nudges for an hour", systemImage: "pause.circle") { Task { await app.nudges.pause(nudge) } }
            Button("See this less often", systemImage: "minus.circle") { Task { await app.nudges.seeLess(nudge) } }
            Button("Skip", systemImage: "clock.arrow.circlepath") { Task { await app.nudges.skip(nudge) } }
        }
        .offset(y: dragY)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { v in
                    // Free upward, rubber-banded downward.
                    dragY = v.translation.height < 0 ? v.translation.height : rubberband(v.translation.height)
                }
                .onEnded { v in
                    let projected = v.translation.height + v.velocity.height * 0.2
                    if projected < -60 {
                        withAnimation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion)) { app.nudges.dismissBanner() }
                    } else {
                        withAnimation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion)) { dragY = 0 }
                    }
                }
        )
        .sensoryFeedback(.success, trigger: accepted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nudge from \(nudge.friendName)")
    }

    var windowLine: String {
        let end = nudge.window.end.formatted(date: .omitted, time: .shortened)
        return nudge.minutes >= 60 ? "Calendars open for the next hour" : "Calendars open · \(nudge.minutes) min until \(end)"
    }

    func rubberband(_ x: CGFloat) -> CGFloat { (x * 200 * 0.55) / (200 + 0.55 * abs(x)) }
}

// MARK: Waiting room

struct WaitingRoomView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let nudge = app.nudges.waiting {
            let outcome = Outcome(nudge)
            FitOrScroll { VStack(spacing: Space.l) {
                Spacer()
                // Figma M16a: two rings expand 80 → 120% while fading, every 1.6 s, half a cycle apart; the avatars
                // breathe 103% in opposite phase (3.2 s). Reduced Motion: rings static at rest.
                MotionTimeline(settlesAt: 0, loops: outcome == .waiting) { beat in
                    let live = outcome == .waiting && !beat.reduceMotion
                    ZStack {
                        if outcome == .waiting {
                            ForEach(0..<2, id: \.self) { i in
                                let ring = live ? Self.ring(beat.t, offset: Double(i) * Motion.Period.pulse / 2) : (scale: 0.8, opacity: 1)
                                Circle().fill(Palette.mint).frame(width: 240, height: 240)
                                    .scaleEffect(ring.scale).opacity(ring.opacity * 0.8)
                            }
                        }
                        Circle().fill(outcome == .waiting ? Palette.mint : Palette.surfaceAlt).frame(width: 180, height: 180)
                        AvatarPair(me: app.session.me?.user.publicUser, friend: nudge.friend, friendName: nudge.friendName, size: 72,
                                   borderColor: outcome == .waiting ? Palette.mint : Palette.surfaceAlt,
                                   leftScale: live ? IdleMotion.breathe(beat.t + 1.6, from: 0, period: 3.2, peak: 1.03) : 1,
                                   rightScale: live ? IdleMotion.breathe(beat.t, from: 0, period: 3.2, peak: 1.03) : 1)
                    }
                    .frame(width: 290, height: 290)
                }

                VStack(spacing: Space.s) {
                    Text(outcome.title(nudge.friendName)).font(Typography.largeTitle).displayTracking()
                        .foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                    switch outcome {
                    case .waiting:
                        if let exp = nudge.expiresAt {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                let left = max(0, Int(exp.timeIntervalSince(ctx.date)))
                                Text("Nudge ends in \(Formatters.clock(left))")
                                    .font(.body.monospacedDigit()).foregroundStyle(Palette.inkSecondary)
                            }
                        }
                        Text("We'll connect you the moment \(nudge.friendName) accepts.")
                            .font(.subheadline).foregroundStyle(Palette.inkTertiary).multilineTextAlignment(.center)
                    case .declined:
                        if let followUp {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("\u{201C}\(followUp.body)\u{201D}").font(.body).foregroundStyle(Palette.ink)
                                Label("Sent automatically · in Messages", systemImage: "sparkles").font(.caption).foregroundStyle(Palette.inkTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .nudgeCard(fill: Palette.surface)
                        } else {
                            Text("No worries. We'll look for another moment.").font(.body).foregroundStyle(Palette.inkSecondary)
                        }
                    case .expired:
                        Text("The window closed before you both could join. We'll look for another one.")
                            .font(.body).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
                    case .connecting:
                        ProgressView().controlSize(.large)
                    }
                }
                .padding(.horizontal, Space.l)
                Spacer()
                NudgeButton(outcome == .waiting ? "Cancel" : "Done", kind: .secondary) {
                    Task { outcome == .waiting ? await app.nudges.leaveWaitingRoom() : await app.nudges.clearWaiting() }
                }
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.m)
            } }
            .nudgeBackground()
            .animation(Motion.resolved(Motion.move, reduceMotion: reduceMotion), value: outcome)
            .sensoryFeedback(.warning, trigger: outcome == .declined)
        } else {
            Palette.bg.ignoresSafeArea()
        }
    }

    /// One ring's scale and opacity `offset` seconds into its 1.6 s cycle.
    static func ring(_ t: Double, offset: Double) -> (scale: Double, opacity: Double) {
        let period = Motion.Period.pulse
        let p = Motion.Curve.outCubic(((t + offset).truncatingRemainder(dividingBy: period)) / period)
        return (0.8 + 0.4 * p, 1 - p)
    }

    var followUp: Message? {
        guard let n = app.nudges.waiting else { return nil }
        return app.messages.threads[n.friend.id]?.last { $0.kind == .autoFollowup && $0.senderId == n.friend.id }
    }

    enum Outcome: Equatable {
        case waiting, declined, expired, connecting

        init(_ n: Nudge) {
            switch n.state {
            case .matched, .inCall: self = .connecting
            case .expired where n.theirResponse == nil || n.theirResponse == .expired: self = .expired
            case .skipped, .cancelled, .ended, .expired: self = .declined
            default: self = (n.theirResponse == .skipped || n.theirResponse == .less) ? .declined : .waiting
            }
        }

        func title(_ name: String) -> String {
            switch self {
            case .waiting: "Waiting for \(name)…"
            case .declined: "\(name) can't right now"
            case .expired: "This nudge ended"
            case .connecting: "Connecting…"
            }
        }
    }
}

// MARK: Incoming (app open)

struct IncomingCallView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let inc = app.incoming {
            VStack(spacing: Space.l) {
                Spacer()
                AvatarView(user: inc.friend, name: inc.name, size: 120)
                VStack(spacing: Space.xs) {
                    Text(inc.name).font(Typography.largeTitle).foregroundStyle(Palette.callInk)
                    Text("Nudge video call").font(.body).foregroundStyle(Palette.callInk.opacity(0.7))
                }
                Spacer()
                HStack(spacing: 72) {
                    VStack(spacing: Space.xs) {
                        CallControlButton(systemImage: "phone.down.fill", label: "Decline", role: .end) {
                            Task { try? await app.api.endCall(inc.callId); app.incoming = nil }
                        }
                        Text("Decline").font(.footnote).foregroundStyle(Palette.callInk.opacity(0.8))
                    }
                    VStack(spacing: Space.xs) {
                        CallControlButton(systemImage: "video.fill", label: "Accept", role: .active) {
                            Task { await app.startCall(callId: inc.callId, viaCallKit: false, friend: inc.friend, name: inc.name) }
                        }
                        Text("Accept").font(.footnote).foregroundStyle(Palette.callInk.opacity(0.8))
                    }
                }
                .padding(.bottom, Space.xxl)
            }
            .frame(maxWidth: .infinity)
            .background(Palette.callScrim.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
        }
    }
}
