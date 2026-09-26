import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("Motion curves")
struct MotionCurveTests {
    typealias C = Motion.Curve

    @Test func progressClamps() {
        #expect(C.progress(-1, from: 0, to: 1) == 0)
        #expect(C.progress(0.5, from: 0, to: 1) == 0.5)
        #expect(C.progress(2, from: 0, to: 1) == 1)
        #expect(C.progress(1, from: 1, to: 1) == 1)
    }

    @Test func easingEndpoints() {
        for f in [C.outCubic, C.inCubic, C.inOutCubic] {
            #expect(f(0) == 0)
            #expect(f(1) == 1)
        }
        #expect(C.outCubic(0.5) == 0.875)
        #expect(C.inCubic(0.5) == 0.125)
        #expect(C.inOutCubic(0.5) == 0.5)
    }

    @Test func springStartsAtZeroOvershootsAndSettles() {
        let playful = Motion.Springs.playful
        #expect(C.spring(playful, 0.1, from: 0.1) == 0)
        let peak = stride(from: 0.0, through: 1.5, by: 0.01).map { C.spring(playful, $0, from: 0) }.max() ?? 0
        #expect(peak > 1.1) // bounce 0.5 overshoots, as in the Figma keyframes (peak ≈ 1.16)
        #expect(abs(C.spring(playful, 3, from: 0) - 1) < 0.01)
        #expect(abs(C.spring(Motion.Springs.settle, 2, from: 0) - 1) < 0.001)
    }

    @Test func oscillateIsZeroBeforeStartAndPeriodic() {
        #expect(C.oscillate(1, period: 6.5, from: 1.25) == 0)
        #expect(abs(C.oscillate(1.25 + 6.5 / 4, period: 6.5, from: 1.25) - 1) < 1e-9)
        #expect(abs(C.oscillate(1.25 + 6.5, period: 6.5, from: 1.25)) < 1e-9)
    }
}

@Suite("Expressive entrance (Figma M02a keyframes)")
struct ExpressiveEntranceTests {
    @Test func startsHiddenAndSettlesByTheEntranceDuration() {
        let parts: [(Double, Bool) -> MotionLayer] = [
            ExpressiveEntrance.art, ExpressiveEntrance.title, ExpressiveEntrance.body,
            ExpressiveEntrance.pageControl, ExpressiveEntrance.primaryAction, ExpressiveEntrance.secondaryAction,
        ]
        for part in parts {
            #expect(part(0, false).opacity == 0)
            let settled = part(ExpressiveEntrance.settled + 1.5, false)
            #expect(abs(settled.opacity - 1) < 1e-9)
            #expect(abs(settled.offsetY) < 0.05)
            #expect(abs(settled.scale - 1) < 0.005)
        }
    }

    @Test func heroFirstActionLast() {
        #expect(ExpressiveEntrance.art(0.5, reduceMotion: false).opacity == 1)
        #expect(ExpressiveEntrance.title(0.35, reduceMotion: false).opacity == 0)
        #expect(ExpressiveEntrance.primaryAction(0.7, reduceMotion: false).opacity == 0)
        #expect(ExpressiveEntrance.primaryAction(0.7, reduceMotion: false).offsetY == 24)
        #expect(ExpressiveEntrance.art(0.1, reduceMotion: false).offsetY == 60)
        #expect(ExpressiveEntrance.art(0.1, reduceMotion: false).scale == 0.8)
        #expect(ExpressiveEntrance.backdropScale(0.05, reduceMotion: false) == 0.6)
    }

    @Test func reduceMotionIsAPlainFade() {
        let art = ExpressiveEntrance.art(0.1, reduceMotion: true)
        #expect(art.offsetY == 0 && art.scale == 1 && art.opacity > 0)
        #expect(ExpressiveEntrance.primaryAction(0.2, reduceMotion: true) == .rest)
        #expect(ExpressiveEntrance.backdropScale(0, reduceMotion: true) == 1)
        #expect(ExpressiveEntrance.activeDotScale(0, reduceMotion: true) == 1)
    }
}

@Suite("Idle motion")
struct IdleMotionTests {
    @Test func swayAndFloatMatchTheSpec() {
        let start = ExpressiveEntrance.settled
        #expect(IdleMotion.artAngle(start).degrees == 0)
        #expect(abs(IdleMotion.artAngle(start + 6.5 / 4).degrees + 1.4) < 1e-9)       // counter-clockwise first
        #expect(abs(IdleMotion.backdropAngle(start + 6.5 / 4).degrees - 2.2) < 1e-9)  // opposite direction
        #expect(abs(IdleMotion.floatY(start + 3.25 / 4) - 4) < 1e-9)                  // down first
        #expect(abs(IdleMotion.backdropBreathe(start + 3.25 / 2) - 1.04) < 1e-9)
        #expect(IdleMotion.backdropBreathe(start) == 1)
    }
}

@Suite("Page stretch")
struct PageStretchTests {
    @Test func outgoingStretchesThenSwapsAtThePeak() {
        #expect(PageStretch.outgoingArt(0, reduceMotion: false).scaleY == 1)
        #expect(abs(PageStretch.outgoingArt(0.2499, reduceMotion: false).scaleY - 1.06) < 0.001)
        #expect(PageStretch.outgoingArt(0.25, reduceMotion: false).opacity == 0)
        #expect(PageStretch.incomingArt(0.2, reduceMotion: false).opacity == 0)
        #expect(abs(PageStretch.incomingArt(0.25, reduceMotion: false).scaleY - 1.06) < 1e-9)
        #expect(PageStretch.incomingArt(0.65, reduceMotion: false).scaleY == 1)
    }

    @Test func copyCrossFadesAndDotStretchesMidTravel() {
        #expect(PageStretch.outgoingCopy(0.15, reduceMotion: false).opacity == 0)
        #expect(PageStretch.incomingTitle(0.3, reduceMotion: false).offsetY == 8)
        #expect(PageStretch.incomingBody(0.8, reduceMotion: false) == .rest)
        #expect(abs(PageStretch.dotStretch(0.15, reduceMotion: false) - 2.2) < 1e-9)
        #expect(abs(PageStretch.dotStretch(0.4, reduceMotion: false) - 1) < 1e-9)
        #expect(abs(PageStretch.dotTravel(0.8, reduceMotion: false) - 1) < 0.02)
    }

    @Test func reduceMotionCrossFadesWithoutMovement() {
        let dt = 0.1
        #expect(PageStretch.outgoingArt(dt, reduceMotion: true).scaleY == 1)
        #expect(abs(PageStretch.outgoingArt(dt, reduceMotion: true).opacity
            + PageStretch.incomingArt(dt, reduceMotion: true).opacity - 1) < 1e-9)
        #expect(PageStretch.incomingTitle(0.2, reduceMotion: true) == .rest)
        #expect(PageStretch.dotTravel(dt, reduceMotion: true) == 0)
        #expect(PageStretch.dotStretch(dt, reduceMotion: true) == 1)
        #expect(PageStretch.duration(reduceMotion: true) == Motion.Durations.fade)
    }
}

@Suite("MotionClock")
struct MotionClockTests {
    @Test func pausesWithoutJumping() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = MotionClock(startedAt: t0)
        #expect(clock.time(at: t0.addingTimeInterval(2)) == 2)
        clock.setRunning(false, at: t0.addingTimeInterval(2))
        #expect(clock.time(at: t0.addingTimeInterval(10)) == 2)
        clock.setRunning(true, at: t0.addingTimeInterval(10))
        #expect(clock.time(at: t0.addingTimeInterval(11)) == 3)
        clock.setRunning(true, at: t0.addingTimeInterval(12)) // no-op while running
        #expect(clock.time(at: t0.addingTimeInterval(12)) == 4)
        #expect(MotionClock().time(at: t0) == 0)
    }
}

@Suite("Beat building blocks")
struct BeatTests {
    @Test func partsStartHiddenAndSettle() {
        let start = Beat(t: 0.5, reduceMotion: false)
        #expect(start.fadeUp(at: 0.5).opacity == 0 && start.fadeUp(at: 0.5).offsetY == 12)
        #expect(start.springUp(at: 0.5).offsetY == 24)
        #expect(start.pop(at: 0.5, from: 0.6).scale == 0.6)
        #expect(start.slideIn(at: 0.5, dx: -12).offsetX == -12)
        #expect(start.springSlide(at: 0.5, dx: 16).offsetX == 16)

        let late = Beat(t: 4, reduceMotion: false)
        for layer in [late.fadeUp(at: 0.5), late.springUp(at: 0.5), late.pop(at: 0.5, from: 0.6), late.slideIn(at: 0.5, dx: -12),
                      late.fadeIn(at: 0.5)] {
            #expect(abs(layer.opacity - 1) < 1e-9)
            #expect(abs(layer.offsetX) < 0.05 && abs(layer.offsetY) < 0.05)
            #expect(abs(layer.scale - 1) < 0.005)
        }
    }

    @Test func reduceMotionIsTheSameFadeForEveryPart() {
        let b = Beat(t: 0.1, reduceMotion: true)
        let parts = [b.fadeUp(at: 0.5), b.springUp(at: 0.9), b.pop(at: 0.3, from: 0.25), b.slideIn(at: 0.6, dx: -12), b.fadeIn(at: 0.85)]
        for p in parts {
            #expect(p == parts[0])
            #expect(p.offsetX == 0 && p.offsetY == 0 && p.scale == 1)
        }
        #expect(!b.idle(after: 0))
        #expect(Beat(t: 1.3, reduceMotion: false).idle(after: 1.25))
    }
}

@Suite("Idle loops")
struct IdleLoopTests {
    @Test func dimBreatheAndFloat() {
        #expect(IdleMotion.dim(0, period: 2.4, low: 0.45) == 1)
        #expect(abs(IdleMotion.dim(1.2, period: 2.4, low: 0.45) - 0.45) < 1e-9)
        #expect(abs(IdleMotion.dim(1.5, period: 2.4, low: 0.45, offset: 0.3) - 0.45) < 1e-9) // later friend lags 0.3 s
        #expect(abs(IdleMotion.breathe(0.8, from: 0, period: 1.6, peak: 1.3) - 1.3) < 1e-9)
        #expect(IdleMotion.breathe(0, from: 0, period: 1.6, peak: 1.3) == 1)
        #expect(abs(IdleMotion.floatOffset(1.25 + 0.8, from: 1.25, period: 3.2, upFirst: true) + 4) < 1e-9)
    }
}
