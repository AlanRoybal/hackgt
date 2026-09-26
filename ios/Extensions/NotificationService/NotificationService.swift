@preconcurrency import UserNotifications

/// Attaches the friend's avatar to nudge and message notifications.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        best = content
        guard let urlString = content.userInfo["avatarUrl"] as? String, let url = URL(string: urlString) else {
            contentHandler(content)
            return
        }
        nonisolated(unsafe) let mutable = content
        nonisolated(unsafe) let deliver = contentHandler
        let task = URLSession.shared.downloadTask(with: url) { location, _, _ in
            if let location {
                let dest = FileManager.default.temporaryDirectory.appending(path: "avatar-\(UUID().uuidString).jpg")
                try? FileManager.default.moveItem(at: location, to: dest)
                if let attachment = try? UNNotificationAttachment(identifier: "avatar", url: dest, options: nil) {
                    mutable.attachments = [attachment]
                }
            }
            deliver(mutable)
        }
        task.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        if let best, let contentHandler { contentHandler(best) }
    }
}
