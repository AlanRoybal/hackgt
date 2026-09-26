import Foundation
import Models

/// A calendar event reduced to what matters for free/busy. Titles never enter this type.
public struct CalendarSpan: Sendable, Hashable {
    public enum Availability: Sendable, Hashable { case busy, free, tentative, unavailable, notSupported }

    public var start: Date
    public var end: Date
    public var availability: Availability
    public var calendarId: String
    public var isAllDay: Bool

    public init(start: Date, end: Date, availability: Availability, calendarId: String, isAllDay: Bool = false) {
        self.start = start
        self.end = end
        self.availability = availability
        self.calendarId = calendarId
        self.isAllDay = isAllDay
    }
}

/// AV-1: busy blocks = events that aren't "free", on enabled calendars, clipped to the window, merged.
public enum BusyExtractor {
    public static let horizon: TimeInterval = 7 * 24 * 3600

    public static func isBusy(_ span: CalendarSpan) -> Bool {
        switch span.availability {
        case .free: return false
        // All-day items (birthdays, holidays, "WFH") only count when explicitly marked busy.
        case .notSupported, .tentative: return !span.isAllDay
        case .busy, .unavailable: return true
        }
    }

    public static func busyBlocks(from spans: [CalendarSpan], disabledCalendarIds: Set<String>, now: Date, horizon: TimeInterval = horizon) -> [BusyBlock] {
        let windowEnd = now.addingTimeInterval(horizon)
        let clipped = spans
            .filter { !disabledCalendarIds.contains($0.calendarId) && isBusy($0) }
            .compactMap { s -> BusyBlock? in
                let start = max(s.start, now)
                let end = min(s.end, windowEnd)
                return end > start ? BusyBlock(start: start, end: end) : nil
            }
        return merge(clipped)
    }

    /// Merges overlapping and touching blocks.
    public static func merge(_ blocks: [BusyBlock]) -> [BusyBlock] {
        let sorted = blocks.sorted { $0.start < $1.start }
        var out: [BusyBlock] = []
        for b in sorted {
            if var last = out.last, b.start <= last.end {
                last.end = max(last.end, b.end)
                out[out.count - 1] = last
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// Free-until for "Free now" UI: nil when busy now; otherwise the next busy start (or nil = open-ended).
    public static func freeUntil(_ blocks: [BusyBlock], now: Date) -> (free: Bool, until: Date?) {
        if blocks.contains(where: { $0.start <= now && now < $0.end }) { return (false, nil) }
        return (true, blocks.filter { $0.start > now }.map(\.start).min())
    }
}
