import DesignSystem
import Models
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// Expanded (long-press) view of a nudge: both avatars and the shared free window (NUD-8).
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<ExpandedNudgeView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func didReceive(_ notification: UNNotification) {
        let info = notification.request.content.userInfo
        let group = Bundle.main.object(forInfoDictionaryKey: "NudgeAppGroup") as? String
            ?? "group." + (Bundle.main.bundleIdentifier?.replacingOccurrences(of: ".NotificationContent", with: "") ?? "")
        let shared = UserDefaults(suiteName: group)
        let model = ExpandedNudgeView.Model(
            myName: shared?.string(forKey: "me.displayName") ?? "You",
            myId: shared?.string(forKey: "me.id") ?? "me",
            friendName: info["friendName"] as? String ?? "Your friend",
            friendId: info["friendId"] as? String ?? "friend",
            avatarURL: (info["avatarUrl"] as? String).flatMap(URL.init(string:)),
            minutes: info["minutes"] as? Int ?? 10,
            start: (info["windowStart"] as? String).flatMap(NudgeJSON.parseDate) ?? Date(),
            end: (info["windowEnd"] as? String).flatMap(NudgeJSON.parseDate)
        )
        let hosting = UIHostingController(rootView: ExpandedNudgeView(model: model))
        hosting.view.backgroundColor = .clear
        host?.view.removeFromSuperview()
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        host = hosting
        preferredContentSize = CGSize(width: view.bounds.width, height: 168)
    }
}

struct ExpandedNudgeView: View {
    struct Model {
        var myName: String
        var myId: String
        var friendName: String
        var friendId: String
        var avatarURL: URL?
        var minutes: Int
        var start: Date
        var end: Date?
    }

    let model: Model

    var body: some View {
        let end = model.end ?? model.start.addingTimeInterval(Double(model.minutes) * 60)
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                AvatarPair(me: PublicUser(id: model.myId, handle: "", displayName: model.myName),
                           friend: PublicUser(id: model.friendId, handle: "", displayName: model.friendName, avatarUrl: model.avatarURL),
                           friendName: model.friendName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You and \(model.friendName)").font(Typography.friendName).foregroundStyle(Palette.ink)
                    Text("Both free for \(model.minutes >= 60 ? "the next hour" : "\(model.minutes) minutes")")
                        .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                }
            }
            FreeWindowBar(start: model.start, end: end)
        }
        .padding(Space.m)
    }
}

/// A small timeline: the shared free window highlighted in mint.
struct FreeWindowBar: View {
    let start: Date
    let end: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            GeometryReader { geo in
                let total: TimeInterval = max(3600, end.timeIntervalSince(start) * 1.6)
                let w = geo.size.width * CGFloat(end.timeIntervalSince(start) / total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceAlt)
                    Capsule().fill(Palette.mintStrong).frame(width: max(24, w))
                }
            }
            .frame(height: 10)
            HStack {
                Text(start.formatted(date: .omitted, time: .shortened))
                Spacer()
                Text("free until \(end.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.inkSecondary)
        }
    }
}
