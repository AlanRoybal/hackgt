import Foundation
import Models

/// `nudge://add/<handle>` (D-13).
public enum AddFriendLink {
    public static let scheme = "nudge"

    public static func url(for handle: String) -> URL {
        URL(string: "\(scheme)://add/\(HandleRule.normalize(handle))")!
    }

    public static func shareText(for handle: String) -> String {
        "Add me on Nudge: @\(HandleRule.normalize(handle))\n\(url(for: handle).absoluteString)"
    }

    /// Returns the handle if the URL is a valid add-friend link.
    public static func handle(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == "add" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1 else { return nil }
        let handle = HandleRule.normalize(parts[0])
        return HandleRule.validate(handle) == nil ? handle : nil
    }
}
