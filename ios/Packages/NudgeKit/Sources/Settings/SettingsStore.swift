import Foundation
import Models
import Networking
import Observation

/// Edits `Settings` optimistically and PATCHes `/me` (SET-1…5).
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: Settings = .default
    public var error: String?
    private let api: NudgeAPI
    public var onMeUpdated: ((MeResponse) -> Void)?

    public init(api: NudgeAPI) { self.api = api }

    public func sync(from me: MeResponse) { settings = me.user.settings }

    public func update(_ change: (inout Settings) -> Void) {
        let before = settings
        var next = settings
        change(&next)
        guard next != before else { return }
        settings = next
        Task {
            do {
                let me = try await api.updateMe(MePatch(settings: SettingsPatch(next)))
                onMeUpdated?(me)
            } catch {
                settings = before
                self.error = error.localizedDescription
            }
        }
    }

    public func preview(_ s: Settings) { settings = s }

    // MARK: Quiet hours helpers ("HH:mm" ↔ Date for pickers)

    public static func date(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = DateComponents()
        c.hour = parts.first ?? 0
        c.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: c) ?? Date()
    }

    public static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
