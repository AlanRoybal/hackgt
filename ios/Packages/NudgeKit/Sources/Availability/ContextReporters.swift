import CoreMotion
import Foundation
import Intents
import Models

/// Reports whether a Focus is on (needs Communication Notifications + user permission).
public enum FocusReporter {
    public static var isAuthorized: Bool { INFocusStatusCenter.default.authorizationStatus == .authorized }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            INFocusStatusCenter.default.requestAuthorization { status in c.resume(returning: status == .authorized) }
        }
    }

    public static func current(now: Date = Date()) -> ContextReport.Focus? {
        guard isAuthorized, let focused = INFocusStatusCenter.default.focusStatus.isFocused else { return nil }
        return ContextReport.Focus(isFocused: focused, at: now)
    }
}

/// Automotive activity with confidence ≥ medium in the last 10 minutes (AV-3).
public enum DrivingReporter {
    public struct Sample: Sendable, Hashable {
        public var automotive: Bool
        public var confidence: Int // 0 low, 1 medium, 2 high
        public var start: Date
        public init(automotive: Bool, confidence: Int, start: Date) {
            self.automotive = automotive
            self.confidence = confidence
            self.start = start
        }
    }

    public static let lookback: TimeInterval = 600

    public static func isDriving(_ samples: [Sample], now: Date) -> Bool {
        samples.contains { $0.automotive && $0.confidence >= 1 && now.timeIntervalSince($0.start) <= lookback }
            || (samples.max(by: { $0.start < $1.start }).map { $0.automotive && $0.confidence >= 1 } ?? false)
    }

    public static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }
    public static var isAuthorized: Bool { CMMotionActivityManager.authorizationStatus() == .authorized }

    public static func current(now: Date = Date()) async -> ContextReport.Driving? {
        guard isAvailable, CMMotionActivityManager.authorizationStatus() != .denied else { return nil }
        let manager = CMMotionActivityManager()
        let samples: [Sample] = await withCheckedContinuation { c in
            manager.queryActivityStarting(from: now.addingTimeInterval(-lookback), to: now, to: OperationQueue()) { activities, _ in
                let s = (activities ?? []).map {
                    Sample(automotive: $0.automotive, confidence: $0.confidence.rawValue, start: $0.startDate)
                }
                c.resume(returning: s)
            }
        }
        return ContextReport.Driving(isDriving: isDriving(samples, now: now), at: now)
    }

    /// Triggers the Motion permission prompt (a zero-length query).
    public static func requestAuthorization() async {
        let manager = CMMotionActivityManager()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            manager.queryActivityStarting(from: Date(), to: Date(), to: OperationQueue()) { _, _ in c.resume() }
        }
    }
}
