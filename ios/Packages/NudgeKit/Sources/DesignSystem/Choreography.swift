import SwiftUI

// Expressive-tier choreography from the Figma Motion page (M02 Welcome keyframes). Every part is a pure
// function of one clock time `t` (seconds since the screen appeared), so values are unit-testable.

/// Visual state of one animated part.
public struct MotionLayer: Equatable, Sendable {
    public var opacity: Double = 1
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public var scale: Double = 1
    /// Extra vertical scale (the Welcome page stretch).
    public var scaleY: Double = 1

    public init(opacity: Double = 1, offsetX: Double = 0, offsetY: Double = 0, scale: Double = 1, scaleY: Double = 1) {
        self.opacity = opacity
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
        self.scaleY = scaleY
    }

    public static let rest = MotionLayer()
    public static let hidden = MotionLayer(opacity: 0)

    /// SwiftUI skips hit-testing fully transparent views, and buttons must be tappable from the first frame.
    public static let tappableOpacity = 0.011

    /// This layer, but never fully transparent, so a button under it stays tappable.
    public var tappable: MotionLayer {
        var layer = self
        layer.opacity = max(opacity, Self.tappableOpacity)
        return layer
    }
}

extension View {
    public func motionLayer(_ layer: MotionLayer, anchor: UnitPoint = .center) -> some View {
        scaleEffect(x: layer.scale, y: layer.scale * layer.scaleY, anchor: anchor)
            .offset(x: layer.offsetX, y: layer.offsetY)
            .opacity(layer.opacity)
    }
}

/// Hero-first, action-last entrance: art grows in on the playful spring, copy fades up 12 pt,
/// the primary action springs up 24 pt last. Settled by `Motion.Durations.entranceExpressive`.
public enum ExpressiveEntrance {
    public static let settled = Motion.Durations.entranceExpressive

    private typealias C = Motion.Curve

    /// Art fades in 0.1–0.5 s, rises 60 pt and grows 80 → 100% from 0.1 s.
    public static func art(_ t: Double, reduceMotion: Bool) -> MotionLayer {
        if reduceMotion { return fade(t) }
        return MotionLayer(opacity: C.outCubic(C.progress(t, from: 0.10, to: 0.50)),
                           offsetY: 60 * (1 - C.outCubic(C.progress(t, from: 0.10, to: 1.05))),
                           scale: 0.8 + 0.2 * C.spring(Motion.Springs.playful, t, from: 0.10))
    }

    /// Backdrop scale inside the art: grows from 60% just ahead of the art.
    public static func backdropScale(_ t: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : 0.6 + 0.4 * C.spring(Motion.Springs.playful, t, from: 0.05)
    }

    public static func title(_ t: Double, reduceMotion: Bool) -> MotionLayer {
        reduceMotion ? fade(t) : fadeUp(t, start: 0.35, fadeEnd: 0.62, riseEnd: 0.80, distance: 12)
    }

    public static func body(_ t: Double, reduceMotion: Bool) -> MotionLayer {
        reduceMotion ? fade(t) : fadeUp(t, start: 0.45, fadeEnd: 0.72, riseEnd: 0.90, distance: 12)
    }

    public static func pageControl(_ t: Double, reduceMotion: Bool) -> MotionLayer {
        reduceMotion ? fade(t) : MotionLayer(opacity: C.outCubic(C.progress(t, from: 0.55, to: 0.73)))
    }

    /// The active page dot pops 40 → 100% at 0.55 s.
    public static func activeDotScale(_ t: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : 0.4 + 0.6 * C.spring(Motion.Springs.pop, t, from: 0.55)
    }

    /// Primary button: fades in 0.7–0.95 s and springs up 24 pt.
    public static func primaryAction(_ t: Double, reduceMotion: Bool) -> MotionLayer {
        if reduceMotion { return fade(t) }
        return MotionLayer(opacity: C.outCubic(C.progress(t, from: 0.70, to: 0.95)),
                           offsetY: 24 * (1 - C.spring(Motion.Springs.pop, t, from: 0.70)))
    }

    /// Secondary action (Skip) arrives last.
    public static func secondaryAction(_ t: Double, reduceMotion: Bool) -> MotionLayer {
        reduceMotion ? fade(t) : MotionLayer(opacity: C.outCubic(C.progress(t, from: 0.90, to: 1.08)))
    }

    /// Reduce Motion: everything cross-fades in together.
    static func fade(_ t: Double) -> MotionLayer {
        MotionLayer(opacity: C.outCubic(C.progress(t, from: 0, to: Motion.Durations.fade)))
    }

    static func fadeUp(_ t: Double, start: Double, fadeEnd: Double, riseEnd: Double, distance: Double) -> MotionLayer {
        MotionLayer(opacity: C.outCubic(C.progress(t, from: start, to: fadeEnd)),
                    offsetY: distance * (1 - C.outCubic(C.progress(t, from: start, to: riseEnd))))
    }
}

/// Slow, small idle loop that starts once the entrance settles. Callers skip it under Reduce Motion.
public enum IdleMotion {
    public static let artSway = 1.4
    public static let backdropSway = 2.2
    public static let float = 4.0
    public static let breathe = 0.04

    private typealias C = Motion.Curve

    /// Art sways ±1.4° over 6.5 s, counter-clockwise first.
    public static func artAngle(_ t: Double, from start: Double = ExpressiveEntrance.settled) -> Angle {
        .degrees(-artSway * C.oscillate(t, period: Motion.Period.sway, from: start))
    }

    /// Backdrop sways ∓2.2°, opposite the art.
    public static func backdropAngle(_ t: Double, from start: Double = ExpressiveEntrance.settled) -> Angle {
        .degrees(backdropSway * C.oscillate(t, period: Motion.Period.sway, from: start))
    }

    /// ±4 pt float, down first.
    public static func floatY(_ t: Double, from start: Double = ExpressiveEntrance.settled) -> Double {
        float * C.oscillate(t, period: Motion.Period.float, from: start)
    }

    /// Backdrop breathes 100 → 104% on the float period.
    public static func backdropBreathe(_ t: Double, from start: Double = ExpressiveEntrance.settled) -> Double {
        guard t > start else { return 1 }
        return 1 + breathe * (1 - cos(2 * .pi * (t - start) / Motion.Period.float)) / 2
    }
}

/// Welcome page change. `dt` is seconds since the change began. The outgoing art stretches to 106% height
/// (ease-in) and swaps at the peak, then the incoming art settles (ease-out). Copy cross-fades out, then
/// the new copy fades up 8 pt. The active dot slides one step on the standard spring, stretching wide
/// mid-travel. Under Reduce Motion it's a plain 0.2 s cross-fade.
public enum PageStretch {
    public static let swapAt = Motion.Durations.stretchOut
    public static let copySwapAt = 0.15
    public static let stretch = 0.06

    private typealias C = Motion.Curve

    public static func duration(reduceMotion: Bool) -> Double { reduceMotion ? Motion.Durations.fade : 0.8 }

    public static func outgoingArt(_ dt: Double, reduceMotion: Bool) -> MotionLayer {
        if reduceMotion { return MotionLayer(opacity: 1 - crossfade(dt)) }
        guard dt < swapAt else { return .hidden }
        return MotionLayer(scaleY: 1 + stretch * C.inCubic(C.progress(dt, from: 0, to: swapAt)))
    }

    public static func incomingArt(_ dt: Double, reduceMotion: Bool) -> MotionLayer {
        if reduceMotion { return MotionLayer(opacity: crossfade(dt)) }
        guard dt >= swapAt else { return .hidden }
        let settle = C.outCubic(C.progress(dt, from: swapAt, to: swapAt + Motion.Durations.stretchIn))
        return MotionLayer(scaleY: 1 + stretch * (1 - settle))
    }

    /// When the copy (and button label) switch to the incoming page. Text can't overlap legibly, so under
    /// Reduce Motion it fades out for the first half of the cross-fade and in for the second.
    public static func copySwap(reduceMotion: Bool) -> Double {
        reduceMotion ? Motion.Durations.fade / 2 : copySwapAt
    }

    public static func outgoingCopy(_ dt: Double, reduceMotion: Bool) -> MotionLayer {
        let end = copySwap(reduceMotion: reduceMotion)
        return MotionLayer(opacity: 1 - (reduceMotion ? C.inOutCubic : C.outCubic)(C.progress(dt, from: 0, to: end)))
    }

    public static func incomingTitle(_ dt: Double, reduceMotion: Bool) -> MotionLayer {
        reduceMotion ? incomingCopyFade(dt)
            : ExpressiveEntrance.fadeUp(dt, start: 0.30, fadeEnd: 0.60, riseEnd: 0.70, distance: 8)
    }

    public static func incomingBody(_ dt: Double, reduceMotion: Bool) -> MotionLayer {
        reduceMotion ? incomingCopyFade(dt)
            : ExpressiveEntrance.fadeUp(dt, start: 0.38, fadeEnd: 0.68, riseEnd: 0.78, distance: 8)
    }

    private static func incomingCopyFade(_ dt: Double) -> MotionLayer {
        MotionLayer(opacity: C.inOutCubic(C.progress(dt, from: Motion.Durations.fade / 2, to: Motion.Durations.fade)))
    }

    /// Fraction of the one-dot step travelled (overshoots slightly). Reduce Motion doesn't slide.
    public static func dotTravel(_ dt: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : C.spring(Motion.Springs.standard, dt, from: 0)
    }

    /// Horizontal stretch of the active dot: 1 → 2.2 → 1.
    public static func dotStretch(_ dt: Double, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        return dt < copySwapAt
            ? 1 + 1.2 * C.outCubic(C.progress(dt, from: 0, to: copySwapAt))
            : 2.2 - 1.2 * C.outCubic(C.progress(dt, from: copySwapAt, to: 0.40))
    }

    /// Reduce Motion's 0.2 s ease-in-out cross-fade, 0 → 1.
    public static func crossfade(_ dt: Double) -> Double {
        C.inOutCubic(C.progress(dt, from: 0, to: Motion.Durations.fade))
    }
}

// MARK: - Building blocks for other screens

/// One moment of a choreography: clock time `t` plus the Reduce Motion setting. Each part builder returns
/// a `MotionLayer`; under Reduce Motion every part is the same 0.2 s fade-in (no move, no scale).
public struct Beat: Sendable {
    public let t: Double
    public let reduceMotion: Bool

    public init(t: Double, reduceMotion: Bool) {
        self.t = t
        self.reduceMotion = reduceMotion
    }

    private typealias C = Motion.Curve

    /// Opacity only.
    public func fadeIn(at start: Double, for duration: Double = 0.25) -> MotionLayer {
        reduceMotion ? rmFade : MotionLayer(opacity: C.outCubic(C.progress(t, from: start, to: start + duration)))
    }

    /// Fades in and rises `distance` pt on ease-out cubic (copy, cards).
    public func fadeUp(at start: Double, fade: Double = 0.27, rise: Double = 0.45, distance: Double = 12) -> MotionLayer {
        reduceMotion ? rmFade : ExpressiveEntrance.fadeUp(t, start: start, fadeEnd: start + fade,
                                                                  riseEnd: start + rise, distance: distance)
    }

    /// Fades in and springs up `distance` pt (primary actions arriving last).
    public func springUp(at start: Double, fade: Double = 0.25, distance: Double = 24,
                         spring: Spring = Motion.Springs.pop) -> MotionLayer {
        if reduceMotion { return rmFade }
        return MotionLayer(opacity: C.outCubic(C.progress(t, from: start, to: start + fade)),
                           offsetY: distance * (1 - C.spring(spring, t, from: start)))
    }

    /// Grows from `scale` to 100% on a spring, fading in over `fade` (0 = visible from the start).
    public func pop(at start: Double, from scale: Double, fade: Double = 0.15,
                    spring: Spring = Motion.Springs.pop) -> MotionLayer {
        if reduceMotion { return rmFade }
        let opacity = fade > 0 ? C.outCubic(C.progress(t, from: start, to: start + fade)) : 1
        return MotionLayer(opacity: opacity, scale: scale + (1 - scale) * C.spring(spring, t, from: start))
    }

    /// Fades in while sliding `dx` pt horizontally into place.
    public func slideIn(at start: Double, dx: Double, fade: Double = 0.24, slide: Double = 0.4) -> MotionLayer {
        if reduceMotion { return rmFade }
        return MotionLayer(opacity: C.outCubic(C.progress(t, from: start, to: start + fade)),
                           offsetX: dx * (1 - C.outCubic(C.progress(t, from: start, to: start + slide))))
    }

    /// Slides `dx` pt into place on a spring (avatars sliding together).
    public func springSlide(at start: Double, dx: Double, fade: Double = 0.2, spring: Spring = Motion.Springs.pop) -> MotionLayer {
        if reduceMotion { return rmFade }
        return MotionLayer(opacity: C.outCubic(C.progress(t, from: start, to: start + fade)),
                           offsetX: dx * (1 - C.spring(spring, t, from: start)))
    }

    /// True once `start` has passed and motion is allowed: idle loops run from here.
    public func idle(after start: Double) -> Bool { !reduceMotion && t > start }

    private var rmFade: MotionLayer { ExpressiveEntrance.fade(t) }
}

extension IdleMotion {
    /// ±`amplitude` pt float; `upFirst` flips the direction the first half-period moves.
    public static func floatOffset(_ t: Double, from start: Double, period: Double = Motion.Period.float,
                             amplitude: Double = IdleMotion.float, upFirst: Bool = false) -> Double {
        (upFirst ? -1 : 1) * amplitude * Motion.Curve.oscillate(t, period: period, from: start)
    }

    /// Scale that breathes from 1 up to `peak` and back every `period`, starting at rest.
    public static func breathe(_ t: Double, from start: Double, period: Double, peak: Double) -> Double {
        guard t > start, period > 0 else { return 1 }
        return 1 + (peak - 1) * (1 - cos(2 * .pi * (t - start) / period)) / 2
    }

    /// Opacity that dips from 1 to `low` and back every `period` (free-status breathe, skeleton pulse).
    public static func dim(_ t: Double, period: Double, low: Double, offset: Double = 0) -> Double {
        guard period > 0 else { return 1 }
        return 1 - (1 - low) * (1 - cos(2 * .pi * (t - offset) / period)) / 2
    }
}

extension EnvironmentValues {
    /// Screenshot capture: timelines render their settled pose instead of running a clock.
    @Entry public var motionSnapshot = false
}

/// Drives a choreography from one clock (`TimelineView(.animation)` + `MotionClock`). The clock stops once
/// the entrance has settled unless the screen has an idle loop; under Reduce Motion it stops after the
/// 0.2 s fade. It also pauses while offscreen, in the background, or while `isInteracting`.
public struct MotionTimeline<Content: View>: View {
    let settlesAt: TimeInterval
    let loops: Bool
    let isInteracting: Bool
    let content: (Beat) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.motionSnapshot) private var snapshot
    @State private var clock = MotionClock()
    @State private var isVisible = false
    @State private var settled = false

    public init(settlesAt: TimeInterval = Motion.Durations.entranceExpressive, loops: Bool = false,
                isInteracting: Bool = false, @ViewBuilder content: @escaping (Beat) -> Content) {
        self.settlesAt = settlesAt
        self.loops = loops
        self.isInteracting = isInteracting
        self.content = content
    }

    private var paused: Bool {
        snapshot || !isVisible || scenePhase == .background || settled || isInteracting
    }

    public var body: some View {
        TimelineView(.animation(paused: paused)) { context in
            content(Beat(t: snapshot ? settlesAt : clock.time(at: context.date), reduceMotion: reduceMotion))
        }
        .onAppear {
            isVisible = true
            if clock.time(at: .now) == 0 { clock = MotionClock(startedAt: .now) }
        }
        .onDisappear { isVisible = false }
        .onChange(of: paused) { _, paused in clock.setRunning(!paused, at: .now) }
        .task(id: [reduceMotion, loops]) {
            settled = false
            guard reduceMotion || !loops else { return }
            let end = reduceMotion ? Motion.Durations.fade : settlesAt
            try? await Task.sleep(for: .seconds(max(end - clock.time(at: .now), 0) + 0.05))
            if !Task.isCancelled { settled = true }
        }
    }
}

/// Spot art on a backdrop with the expressive idle loop: the art floats and sways, the backdrop sways the
/// other way and breathes 104%. Used by permission primers and empty states.
public struct IdleArt<Art: View, Backdrop: View>: View {
    let beat: Beat
    let idleFrom: Double
    let upFirst: Bool
    let art: Art
    let backdrop: Backdrop

    public init(beat: Beat, idleFrom: Double = ExpressiveEntrance.settled, upFirst: Bool = false,
                @ViewBuilder art: () -> Art, @ViewBuilder backdrop: () -> Backdrop) {
        self.beat = beat
        self.idleFrom = idleFrom
        self.upFirst = upFirst
        self.art = art()
        self.backdrop = backdrop()
    }

    public var body: some View {
        let t = beat.t
        let idle = beat.idle(after: idleFrom)
        ZStack {
            backdrop
                .scaleEffect(idle ? IdleMotion.backdropBreathe(t, from: idleFrom) : 1)
                .rotationEffect(idle ? IdleMotion.backdropAngle(t, from: idleFrom) : .zero)
            art
                .rotationEffect(idle ? IdleMotion.artAngle(t, from: idleFrom) : .zero)
                .offset(y: idle ? IdleMotion.floatOffset(t, from: idleFrom, upFirst: upFirst) : 0)
        }
    }
}
