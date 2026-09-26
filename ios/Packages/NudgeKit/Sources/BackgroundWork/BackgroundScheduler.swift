import Availability
import BackgroundTasks
import Foundation
import os
import PhotoIndex

/// BGAppRefresh (calendar + context) and BGProcessing (photo indexing, prefer charging).
public enum BackgroundScheduler {
    public static let refreshId = "app.nudge.refresh"
    public static let photosId = "app.nudge.photos"
    private static let log = Logger(subsystem: "app.nudge", category: "bg")

    /// Call from `application(_:didFinishLaunchingWithOptions:)`, before launch returns.
    @MainActor
    public static func register(sync: @escaping @MainActor () -> AvailabilitySync?, photos: @escaping @MainActor () -> PhotoIndexer?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { task in
            nonisolated(unsafe) let t = task
            let work = Task { @MainActor in
                scheduleRefresh()
                await sync()?.sync(reason: "BGAppRefresh")
                t.setTaskCompleted(success: true)
            }
            t.expirationHandler = { work.cancel() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: photosId, using: nil) { task in
            nonisolated(unsafe) let t = task
            let work = Task { @MainActor in
                schedulePhotos()
                await photos()?.run(reason: "BGProcessing")
                t.setTaskCompleted(success: true)
            }
            t.expirationHandler = { work.cancel() }
        }
    }

    public static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        do { try BGTaskScheduler.shared.submit(r) } catch { log.info("refresh not scheduled: \(String(describing: error), privacy: .public)") }
    }

    public static func schedulePhotos() {
        let r = BGProcessingTaskRequest(identifier: photosId)
        r.requiresExternalPower = true
        r.requiresNetworkConnectivity = true
        r.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do { try BGTaskScheduler.shared.submit(r) } catch { log.info("photos not scheduled: \(String(describing: error), privacy: .public)") }
    }
}
