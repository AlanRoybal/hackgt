import Availability
import DesignSystem
import Friends
import Models
import Networking
import PhotoIndex
import SwiftUI
import UserNotifications
import AVFoundation

/// Phone (optional) → permission primers → add first friends (SPEC screens 6–8).
struct SetupFlow: View {
    @Environment(AppModel.self) private var app
    @State private var step: Step = .phone

    enum Step: Hashable { case phone, permission(Int), friends }

    var body: some View {
        ZStack {
            switch step {
            case .phone:
                PhoneView(onDone: { step = .permission(0) })
            case .permission(let i):
                PermissionPrimerView(kind: PermissionKind.onboarding[i]) {
                    step = i + 1 < PermissionKind.onboarding.count ? .permission(i + 1) : .friends
                }
                .id(i)
            case .friends:
                AddFirstFriendsView { app.completeOnboarding() }
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        .animation(Motion.move, value: step)
    }
}

// MARK: Phone

struct PhoneView: View {
    @Environment(AppModel.self) private var app
    var onDone: () -> Void
    var fromSettings = false
    var startSent = false
    @State private var phone = ""
    @State private var code = ""
    @State private var sent = false
    @State private var working = false
    @State private var error: String?
    private let hasher = PhoneHasher()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(sent ? "Enter the code" : "Add your number").font(Typography.largeTitle).displayTracking().foregroundStyle(Palette.ink)
                Text(sent ? "We sent a 6-digit code to \(hasher.e164(phone) ?? phone)."
                          : "Let friends find you from their contacts. Optional, and never shown to anyone.")
                    .font(.body).foregroundStyle(Palette.inkSecondary)
            }
            .padding(.top, fromSettings ? Space.m : Space.xl)

            if sent {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .textFieldStyle(NudgeTextFieldStyle(error == nil ? .focused : .error))
                    .onChange(of: code) { _, c in if c.count == 6 { Task { await verify() } } }
            } else {
                TextField("(555) 123-4567", text: $phone)
                    .keyboardType(.phonePad).textContentType(.telephoneNumber)
                    .textFieldStyle(NudgeTextFieldStyle(error == nil ? .normal : .error))
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Palette.roseStrong) }
            Spacer()
            VStack(spacing: Space.xs) {
                NudgeButton(sent ? "Verify" : "Send code", isLoading: working) { Task { sent ? await verify() : await send() } }
                    .disabled(sent ? code.count != 6 : hasher.e164(phone) == nil)
                if !fromSettings {
                    Button("Skip for now", action: onDone)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.m)
        .nudgeBackground()
        .onAppear { if startSent { phone = "(415) 555-2671"; sent = true } }
    }

    private func send() async {
        guard let e = hasher.e164(phone) else { return }
        working = true
        defer { working = false }
        do { try await app.api.startPhoneVerification(e164: e); sent = true; error = nil } catch { self.error = error.localizedDescription }
    }

    private func verify() async {
        working = true
        defer { working = false }
        do {
            app.apply(me: try await app.api.verifyPhone(code: code))
            onDone()
        } catch {
            self.error = "That code didn't match. Try again."
            code = ""
        }
    }
}

// MARK: Permission primers

enum PermissionKind: String, CaseIterable, Identifiable {
    case notifications, calendar, photos, contacts, cameraMic, focus, motion
    var id: String { rawValue }

    static let onboarding: [PermissionKind] = [.notifications, .calendar, .photos, .contacts, .cameraMic, .focus, .motion]

    var illustration: Illustration.Kind {
        switch self {
        case .notifications: .notifications
        case .calendar: .calendar
        case .photos: .photos
        case .contacts: .contacts
        case .cameraMic: .camera
        case .focus: .focus
        case .motion: .motion
        }
    }

    var title: String {
        switch self {
        case .notifications: "Get nudged at the right moment"
        case .calendar: "Know when you're free"
        case .photos: "Bring photos into the conversation"
        case .contacts: "Find friends you already know"
        case .cameraMic: "See and hear each other"
        case .focus: "Respect your Focus"
        case .motion: "Never while driving"
        }
    }

    var body: String {
        switch self {
        case .notifications: "Nudges arrive as notifications, even when Nudge is closed. Accept or skip right from your lock screen."
        case .calendar: "Nudge reads when you're busy so it only nudges when you and a friend are both free. Event names never leave your phone."
        case .photos: "Photos from the last 30 days are analyzed so the ones you mention can appear. You choose before anything is shown."
        case .contacts: "Numbers are scrambled on your phone before we check which contacts use Nudge. Nothing is stored."
        case .cameraMic: "Used for video calls, and to find photos you mention while you talk."
        case .focus: "When a Focus is on, we'll hold your nudges."
        case .motion: "Nudge checks if you're in a car so it never interrupts a drive."
        }
    }

    var denied: Bool {
        switch self {
        case .calendar: EKAuthorizationStatusHelper.denied
        case .photos: PHAuthorizationStatusHelper.denied
        case .cameraMic: AVCaptureDevice.authorizationStatus(for: .video) == .denied
        default: false
        }
    }

    @MainActor
    func request(_ app: AppModel) async {
        switch self {
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UIApplication.shared.registerForRemoteNotifications()
        case .calendar:
            if await app.availability.requestAccess() { await app.availability.sync(reason: "calendar granted") }
        case .photos:
            if await app.photos.requestAccess() { Task { await app.photos.run(reason: "photos granted") } }
        case .contacts:
            _ = try? await CNContactStoreHelper.request()
        case .cameraMic:
            _ = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .focus:
            _ = await FocusReporter.requestAuthorization()
        case .motion:
            await DrivingReporter.requestAuthorization()
        }
    }
}

import Contacts
import EventKit
import Photos

enum EKAuthorizationStatusHelper { static var denied: Bool { EKEventStore.authorizationStatus(for: .event) == .denied } }
enum PHAuthorizationStatusHelper { static var denied: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied } }
enum CNContactStoreHelper { static func request() async throws -> Bool { try await CNContactStore().requestAccess(for: .contacts) } }

struct PermissionPrimerView: View {
    @Environment(AppModel.self) private var app
    let kind: PermissionKind
    var forceDenied = false
    var onDone: () -> Void
    @State private var working = false

    var body: some View {
        let denied = forceDenied || kind.denied
        VStack(spacing: Space.l) {
            Spacer()
            Illustration(kind.illustration)
                .frame(width: 220, height: 160)
                .padding(.vertical, Space.l)
                .frame(maxWidth: .infinity)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
            VStack(spacing: Space.s) {
                Text(kind.title).font(Typography.largeTitle).displayTracking().foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                Text(denied ? "Access is turned off. You can turn it on in Settings whenever you like." : kind.body)
                    .font(.body).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: Space.xs) {
                if denied {
                    NudgeButton("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                } else {
                    NudgeButton("Continue", isLoading: working) {
                        Task {
                            working = true
                            if !app.isPreview { await kind.request(app) }
                            working = false
                            onDone()
                        }
                    }
                }
                Button("Not now", action: onDone)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.inkSecondary).frame(minHeight: 44)
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.m)
        .nudgeBackground()
    }
}

// MARK: Add first friends

struct AddFirstFriendsView: View {
    @Environment(AppModel.self) private var app
    var onDone: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Add your people").font(Typography.largeTitle).displayTracking().foregroundStyle(Palette.ink)
                        Text("Nudge works best with the few people you'd always pick up for.")
                            .font(.body).foregroundStyle(Palette.inkSecondary)
                    }
                    .padding(.top, Space.xl)

                    TextField("Search by handle", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(NudgeTextFieldStyle())
                        .onChange(of: query) { _, q in app.friends.search(q) }

                    if !query.isEmpty {
                        UserResultsList(results: app.friends.searchResults)
                    } else {
                        if !app.friends.contactMatches.isEmpty {
                            SectionHeader("From your contacts")
                            UserResultsList(results: app.friends.contactMatches)
                        }
                        ShareLinkCard()
                    }
                }
                .padding(.horizontal, Space.margin)
            }
            NudgeButton("Done", kind: .primary) { onDone() }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s)
        }
        .nudgeBackground()
        .task { if !app.isPreview, FriendsStore.contactsAuthorized { await app.friends.matchContacts() } }
    }
}

struct UserResultsList: View {
    @Environment(AppModel.self) private var app
    let results: [SearchResult]

    var body: some View {
        CardList {
            ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                AdaptiveStack(spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        AvatarView(user: r.publicUser, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.displayName).font(Typography.friendName).foregroundStyle(Palette.ink)
                            Text("@\(r.handle)").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    RelationButton(result: r).fixedSize()
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                if i < results.count - 1 { RowDivider() }
            }
        }
    }
}

struct RelationButton: View {
    @Environment(AppModel.self) private var app
    let result: SearchResult

    var body: some View {
        switch result.relation {
        case .none:
            NudgeButton("Add", kind: .primary, size: .small, fullWidth: false) { Task { await app.friends.add(userId: result.id) } }
        case .incoming:
            NudgeButton("Accept", kind: .accept, size: .small, fullWidth: false) { Task { await app.friends.accept(result.id) } }
        case .requested:
            Pill("Requested", tint: .sky)
        case .friends:
            Pill("Friends", tint: .mint, systemImage: "checkmark")
        case .blocked:
            Pill("Blocked", tint: .rose)
        }
    }
}

struct ShareLinkCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let handle = app.session.me?.user.handle ?? "you"
        HStack(spacing: Space.m) {
            Image(systemName: "link").font(.headline).foregroundStyle(Palette.lavenderStrong)
                .frame(width: 44, height: 44).background(Palette.lavender, in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Invite with your link").font(.headline).foregroundStyle(Palette.ink)
                Text("nudge://add/\(handle)").font(.subheadline).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
            Spacer()
            SwiftUI.ShareLink(item: ShareLinkText.text(handle)) {
                Text("Share").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.lavenderStrong)
            }
        }
        .nudgeCard()
    }
}

enum ShareLinkText {
    static func text(_ handle: String) -> String { AddFriendLink.shareText(for: handle) }
}
