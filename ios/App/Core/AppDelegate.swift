import BackgroundWork
import Models
import Nudges
import PhotoIndex
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let app = AppModel.shared
        UNUserNotificationCenter.current().delegate = self
        NudgeCenter.registerCategories()
        if !app.isPreview {
            BackgroundScheduler.register(sync: { AppModel.shared.availability }, photos: { AppModel.shared.photos })
            // Register PushKit immediately so a VoIP push that launched us is delivered.
            app.voip.register()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.didRegister(apnsToken: deviceToken)
    }

    // Completion-handler forms throughout: the Swift `async` forms of these delegate methods finish off the main
    // thread, and UIKit asserts (SIGABRT) when the completion runs there — seen when Accept on a nudge
    // notification launched the closed app (D-306).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        nonisolated(unsafe) let info = userInfo
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            await AppModel.shared.handleBackgroundPush(info)
            done(.newData)
        }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == BackgroundUploader.identifier { BackgroundUploader.shared.setCompletionHandler(completionHandler) } else { completionHandler() }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Foreground: nudges get our own drop-down banner instead of the system one (NUD-9).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let type = info["type"] as? String
        let nudgeId = info["nudgeId"] as? String
        let friendId = info["friendId"] as? String
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            let app = AppModel.shared
            switch type.flatMap(PushKind.init(rawValue:)) {
            case .nudge:
                if let nudgeId { Task { await app.nudges.present(nudgeId: nudgeId) } }
                done([])
            case .followUpDraft:
                // Open app: the approval sheet replaces the system banner.
                if let nudgeId { Task { await app.nudges.presentFollowUp(nudgeId: nudgeId) } }
                done([])
            case .messageNew:
                done(app.visibleThreadId == friendId ? [] : [.banner, .sound, .list])
            default:
                done([.banner, .sound, .list])
            }
        }
    }

    /// Lock-screen actions (works after termination: iOS launches us in the background).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let nudgeId = info["nudgeId"] as? String
        let friendId = info["friendId"] as? String
        let type = info["type"] as? String
        let typedText = (response as? UNTextInputNotificationResponse)?.userText
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            let app = AppModel.shared
            // Any notification interaction is a chance to refresh availability (AV-1).
            async let sync: Void = app.availability.sync(reason: "notification action")
            if type == PushKind.nudge.rawValue, let nudgeId {
                await app.nudges.handleNotificationAction(action, nudgeId: nudgeId)
            } else if type == PushKind.followUpDraft.rawValue, let nudgeId {
                await app.nudges.handleFollowUpAction(action, nudgeId: nudgeId, typedText: typedText)
            } else if type == PushKind.messageNew.rawValue, let friendId {
                app.openThread(friendId)
            }
            await sync
            done()
        }
    }
}
