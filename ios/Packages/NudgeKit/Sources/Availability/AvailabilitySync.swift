import EventKit
import Foundation
import Models
import Networking
import Observation
import os

/// Uploads free/busy + context whenever the app gets a chance to run (AV-1, AV-3).
@MainActor
@Observable
public final class AvailabilitySync {
    public private(set) var calendars: [CalendarInfo] = []
    public private(set) var lastSyncedAt: Date?
    public private(set) var lastError: String?
    public var disabledCalendarIds: Set<String> {
        didSet { defaults.set(Array(disabledCalendarIds), forKey: Self.disabledKey) }
    }

    private let api: NudgeAPI
    private let provider: AppleCalendarProvider
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var inFlight: Task<Void, Never>?
    private let log = Logger(subsystem: "app.nudge", category: "availability")
    static let disabledKey = "disabledCalendarIds"

    public init(api: NudgeAPI, provider: AppleCalendarProvider = AppleCalendarProvider(), defaults: UserDefaults = .standard) {
        self.api = api
        self.provider = provider
        self.defaults = defaults
        self.disabledCalendarIds = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    public var isAuthorized: Bool { AppleCalendarProvider.isAuthorized }

    public func requestAccess() async -> Bool {
        let ok = await provider.requestAccess()
        if ok { await refreshCalendars(); startObserving() }
        return ok
    }

    public func refreshCalendars() async {
        calendars = await provider.calendars()
    }

    public func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: provider.store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sync(reason: "EKEventStoreChanged") }
        }
    }

    public func setCalendar(_ id: String, enabled: Bool) {
        if enabled { disabledCalendarIds.remove(id) } else { disabledCalendarIds.insert(id) }
        Task { await sync(reason: "calendar toggle") }
    }

    /// Coalesces concurrent triggers into one upload.
    public func sync(reason: String) async {
        if let inFlight { await inFlight.value; return }
        let task = Task { await self.performSync(reason: reason) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performSync(reason: String) async {
        let now = Date()
        do {
            if AppleCalendarProvider.isAuthorized {
                let spans = await provider.spans(from: now, to: now.addingTimeInterval(BusyExtractor.horizon))
                let blocks = BusyExtractor.busyBlocks(from: spans, disabledCalendarIds: disabledCalendarIds, now: now)
                try await api.uploadAvailability(AvailabilityUpload(busyBlocks: blocks, syncedAt: now, tz: TimeZone.current.identifier))
            }
            let report = ContextReport(focus: FocusReporter.current(now: now), driving: await DrivingReporter.current(now: now))
            if report.focus != nil || report.driving != nil { try await api.reportContext(report) }
            lastSyncedAt = now
            lastError = nil
            log.info("synced (\(reason, privacy: .public))")
        } catch {
            lastError = error.localizedDescription
            log.error("sync failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    public func preview(calendars: [CalendarInfo], disabled: Set<String>) {
        self.calendars = calendars
        self.disabledCalendarIds = disabled
    }
}
