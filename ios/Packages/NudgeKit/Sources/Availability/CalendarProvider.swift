import EventKit
import Foundation
import Models

public struct CalendarInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var colorHex: String
    public var source: String

    public init(id: String, title: String, colorHex: String, source: String) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.source = source
    }
}

/// AV-4. Apple is implemented on device; Google will be a server-side provider (OAuth + sync on the
/// server), so the client-side type only exists to show "Coming soon".
public protocol CalendarProvider: Sendable {
    var id: String { get }
    var isOnDevice: Bool { get }
    func requestAccess() async -> Bool
    func calendars() async -> [CalendarInfo]
    func spans(from: Date, to: Date) async -> [CalendarSpan]
}

public final class AppleCalendarProvider: CalendarProvider, @unchecked Sendable {
    public let id = "apple"
    public let isOnDevice = true
    public let store = EKEventStore()

    public init() {}

    public static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func calendars() async -> [CalendarInfo] {
        guard Self.isAuthorized else { return [] }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, colorHex: $0.cgColor.map(Self.hex) ?? "#9AA0AE", source: $0.source.title)
        }
    }

    public func spans(from: Date, to: Date) async -> [CalendarSpan] {
        guard Self.isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { e in
            CalendarSpan(start: e.startDate, end: e.endDate, availability: Self.map(e.availability),
                         calendarId: e.calendar.calendarIdentifier, isAllDay: e.isAllDay)
        }
    }

    static func map(_ a: EKEventAvailability) -> CalendarSpan.Availability {
        switch a {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: .notSupported
        @unknown default: .notSupported
        }
    }

    static func hex(_ c: CGColor) -> String {
        let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0.6, 0.6, 0.6]
        let rgb = comps.count >= 3 ? comps : [comps[0], comps[0], comps[0]]
        return String(format: "#%02X%02X%02X", Int(rgb[0] * 255), Int(rgb[1] * 255), Int(rgb[2] * 255))
    }
}

/// Placeholder for the server-side Google provider. Not built yet (SPEC AV-4).
public struct GoogleCalendarProvider: CalendarProvider {
    public let id = "google"
    public let isOnDevice = false
    public init() {}
    public func requestAccess() async -> Bool { false }
    public func calendars() async -> [CalendarInfo] { [] }
    public func spans(from: Date, to: Date) async -> [CalendarSpan] { [] }
}
