import Foundation
import Models
import Networking
import Observation
import UserNotifications
import os

public struct ToastMessage: Identifiable, Hashable, Sendable {
    public enum Action: Hashable, Sendable { case undoFrequency }
    public var id = UUID()
    public var text: String
    public var action: Action?
    public var actionTitle: String?

    public init(text: String, action: Action? = nil, actionTitle: String? = nil) {
        self.text = text
        self.action = action
        self.actionTitle = actionTitle
    }
}

/// A follow-up the server drafted after I skipped; nothing is sent until I approve it (NUD-12).
public struct FollowUpDraft: Identifiable, Hashable, Sendable {
    public var nudgeId: String
    public var friendName: String
    public var body: String
    public var id: String { nudgeId }

    public init(nudgeId: String, friendName: String, body: String) {
        self.nudgeId = nudgeId
        self.friendName = friendName
        self.body = body
    }
}

/// Owns everything nudge-shaped on the client: the in-app banner, the waiting room, See less + Undo.
@MainActor
@Observable
public final class NudgeCenter {
    /// Drop-down banner for a nudge that arrived while the app is open (NUD-9).
    public private(set) var banner: Nudge?
    /// Nudge the user accepted and is waiting on (NUD-10/11/12).
    public private(set) var waiting: Nudge?
    public var toast: ToastMessage?
    public var error: String?
    /// Drafted follow-up awaiting my approval.
    public private(set) var followUp: FollowUpDraft?

    private let api: NudgeAPI
    private let socket: EventSocket?
    private let log = Logger(subsystem: "app.nudge", category: "nudges")

    /// Called when both accepted and there's a call to join.
    public var onMatched: ((_ callId: String, _ nudge: Nudge?) -> Void)?
    /// Called when a response changed the user's settings (See less / Undo).
    public var onMeUpdated: ((MeResponse) -> Void)?

    public init(api: NudgeAPI, socket: EventSocket?) {
        self.api = api
        self.socket = socket
    }

    // MARK: Notification categories

    public nonisolated static func registerCategories() {
        let accept = UNNotificationAction(identifier: NotificationIDs.accept, title: "Accept", options: [.foreground],
                                          icon: UNNotificationActionIcon(systemImageName: "phone.fill"))
        let skip = UNNotificationAction(identifier: NotificationIDs.skip, title: "Skip", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath"))
        let less = UNNotificationAction(identifier: NotificationIDs.less, title: "See this less often", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "minus.circle"))
        let nudge = UNNotificationCategory(identifier: NotificationIDs.nudgeCategory, actions: [accept, skip, less],
                                           intentIdentifiers: [], options: [])
        let message = UNNotificationCategory(identifier: NotificationIDs.messageCategory, actions: [], intentIdentifiers: [], options: [])
        let send = UNNotificationAction(identifier: NotificationIDs.sendFollowUp, title: "Send", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "paperplane.fill"))
        let edit = UNTextInputNotificationAction(identifier: NotificationIDs.editFollowUp, title: "Edit…", options: [],
                                                 icon: UNNotificationActionIcon(systemImageName: "pencil"),
                                                 textInputButtonTitle: "Send", textInputPlaceholder: "Your message")
        let discard = UNNotificationAction(identifier: NotificationIDs.discardFollowUp, title: "Don't send", options: [.destructive],
                                           icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let followUp = UNNotificationCategory(identifier: NotificationIDs.followUpCategory, actions: [send, edit, discard],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([nudge, message, followUp])
    }

    // MARK: Inputs

    /// A nudge push arrived while the app is in the foreground: show our own banner instead.
    public func present(nudgeId: String) async {
        do {
            let n = try await api.nudge(nudgeId)
            guard !n.state.isTerminal else { return }
            banner = n
        } catch {
            log.error("fetch nudge: \(String(describing: error), privacy: .public)")
        }
    }

    public func refreshActive() async {
        guard let n = try? await api.activeNudge() else { return }
        if n.myResponse == .accepted, !n.state.isTerminal {
            waiting = n
            await socket?.setWaiting(nudgeId: n.id)
        } else if Self.needsResponse(n) {
            banner = n
        }
    }

    /// A live nudge I haven't answered yet.
    public static func needsResponse(_ n: Nudge) -> Bool {
        n.myResponse == nil && (n.state == .pending || n.state == .acceptedByOne)
    }

    public func apply(_ event: ServerEvent) {
        switch event {
        case .nudgeUpdated(let n):
            if banner?.id == n.id {
                banner = n.state.isTerminal || n.myResponse != nil ? nil : n
            } else if banner == nil, waiting?.id != n.id, Self.needsResponse(n) {
                // The WebSocket usually beats the APNs push while the app is open; don't wait for the push.
                banner = n
            }
            if waiting?.id == n.id {
                waiting = n
                if n.state == .matched || n.state == .inCall, let callId = n.callId { onMatched?(callId, n) }
            }
            if n.state.isTerminal { removeDelivered(nudgeId: n.id) }
            showFollowUp(from: n)
        case .callMatched(let callId, let nudgeId):
            banner = banner?.id == nudgeId ? nil : banner
            onMatched?(callId, waiting?.id == nudgeId ? waiting : nil)
        default:
            break
        }
    }

    // MARK: Actions

    public func accept(_ nudge: Nudge) async {
        banner = nil
        do {
            await enterWaitingRoom(try await api.respond(nudgeId: nudge.id, action: .accept))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Shows the waiting room for a nudge I've already accepted (e.g. a "Call now" the server created pre-accepted).
    public func enterWaitingRoom(_ n: Nudge) async {
        banner = banner?.id == n.id ? nil : banner
        waiting = n
        await socket?.setWaiting(nudgeId: n.id)
        if (n.state == .matched || n.state == .inCall), let callId = n.callId { onMatched?(callId, n) }
    }

    public func skip(_ nudge: Nudge) async {
        banner = nil
        if let n = try? await api.respond(nudgeId: nudge.id, action: .skip) { showFollowUp(from: n) }
    }

    /// Long-press → "See this less often": counts as skip and steps frequency down, with Undo (NUD-9).
    public func seeLess(_ nudge: Nudge?) async {
        banner = nil
        do {
            if let nudge { showFollowUp(from: try await api.respond(nudgeId: nudge.id, action: .less)) }
            let me = try await (nudge == nil ? api.frequencyLess() : api.me())
            onMeUpdated?(me)
            toast = ToastMessage(text: "Nudges set to \(me.user.settings.frequency.title)", action: .undoFrequency, actionTitle: "Undo")
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func undoLess() async {
        toast = nil
        do { onMeUpdated?(try await api.frequencyUndo()) } catch { self.error = error.localizedDescription }
    }

    public func pause(_ nudge: Nudge) async {
        do {
            _ = try await api.respond(nudgeId: nudge.id, action: .pause)
            banner = nil
            toast = ToastMessage(text: "Automatic nudges paused for an hour")
        } catch { self.error = error.localizedDescription }
    }

    public func dismissBanner() { banner = nil }

    // MARK: Follow-up approval

    /// Shows (or clears) the approval sheet from a nudge's latest state. A draft resolved elsewhere clears it.
    private func showFollowUp(from n: Nudge) {
        if let body = n.followUpDraft {
            if followUp?.nudgeId != n.id { followUp = FollowUpDraft(nudgeId: n.id, friendName: n.friendName, body: body) }
        } else if followUp?.nudgeId == n.id {
            followUp = nil
        }
    }

    /// A follow-up push arrived while the app is open, or its notification was tapped: show the sheet.
    public func presentFollowUp(nudgeId: String) async {
        guard let n = try? await api.nudge(nudgeId) else { return }
        showFollowUp(from: n)
    }

    /// Sends the draft (as written or edited). Returns false if it failed so the sheet can stay up.
    @discardableResult
    public func sendFollowUp(_ draft: FollowUpDraft, body: String) async -> Bool {
        do {
            _ = try await api.resolveFollowUp(nudgeId: draft.nudgeId, send: true, body: body)
            finishFollowUp(draft.nudgeId)
            toast = ToastMessage(text: "Sent to \(draft.friendName)")
            return true
        } catch APIError.server(status: 409, _, _) {
            finishFollowUp(draft.nudgeId)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Hides the sheet without resolving the draft.
    public func dismissFollowUp() { followUp = nil }

    public func discardFollowUp(_ draft: FollowUpDraft) async {
        finishFollowUp(draft.nudgeId)
        _ = try? await api.resolveFollowUp(nudgeId: draft.nudgeId, send: false)
    }

    /// Lock-screen Send / Edit / Don't send on a follow-up notification (works when the app was terminated).
    public func handleFollowUpAction(_ actionId: String, nudgeId: String, typedText: String?) async {
        switch actionId {
        case NotificationIDs.sendFollowUp:
            _ = try? await api.resolveFollowUp(nudgeId: nudgeId, send: true)
        case NotificationIDs.editFollowUp:
            let text = typedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            _ = try? await api.resolveFollowUp(nudgeId: nudgeId, send: !text.isEmpty, body: text.isEmpty ? nil : text)
        case NotificationIDs.discardFollowUp:
            _ = try? await api.resolveFollowUp(nudgeId: nudgeId, send: false)
        case UNNotificationDefaultActionIdentifier:
            await presentFollowUp(nudgeId: nudgeId)
            return
        default:
            return
        }
        finishFollowUp(nudgeId)
    }

    private func finishFollowUp(_ nudgeId: String) {
        if followUp?.nudgeId == nudgeId { followUp = nil }
        removeDelivered(nudgeId: nudgeId, kind: .followUpDraft)
    }

    public func leaveWaitingRoom() async {
        guard let w = waiting else { return }
        waiting = nil
        await socket?.setWaiting(nudgeId: nil)
        if !w.state.isTerminal { _ = try? await api.cancelNudge(w.id) }
    }

    public func clearWaiting() async {
        waiting = nil
        await socket?.setWaiting(nudgeId: nil)
    }

    /// Handles a notification action tapped on the lock screen (works when the app was terminated).
    public func handleNotificationAction(_ actionId: String, nudgeId: String) async {
        switch actionId {
        case NotificationIDs.accept, UNNotificationDefaultActionIdentifier:
            if let n = try? await api.nudge(nudgeId), !n.state.isTerminal { await accept(n) }
        case NotificationIDs.skip:
            _ = try? await api.respond(nudgeId: nudgeId, action: .skip)
        case NotificationIDs.less:
            _ = try? await api.respond(nudgeId: nudgeId, action: .less)
            if let me = try? await api.me() { onMeUpdated?(me) }
        default: break
        }
    }

    /// Removes the delivered notifications of one kind (the nudge itself by default) for a nudge.
    public nonisolated func removeDelivered(nudgeId: String, kind: PushKind = .nudge) {
        // UNUserNotificationCenter asserts outside an app/extension bundle (e.g. the package test runner).
        guard ["app", "appex"].contains(Bundle.main.bundleURL.pathExtension) else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let notes = await center.deliveredNotifications()
            let ids = notes.filter {
                let info = $0.request.content.userInfo
                return (info["nudgeId"] as? String) == nudgeId && (info["type"] as? String) == kind.rawValue
            }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: Preview

    public func preview(banner: Nudge? = nil, waiting: Nudge? = nil, toast: ToastMessage? = nil, followUp: FollowUpDraft? = nil) {
        self.followUp = followUp
        self.banner = banner
        self.waiting = waiting
        self.toast = toast
    }
}
