import Availability
import DesignSystem
import Models
import PhotoIndex
import Settings
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.l) {
                    if let me = app.session.me?.user {
                        NavigationLink { AccountSettingsView() } label: {
                            HStack(spacing: Space.m) {
                                AvatarView(user: me.publicUser, size: 56)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(me.displayName).font(Typography.friendName).foregroundStyle(Palette.ink)
                                    Text("@\(me.handle)").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkTertiary)
                            }
                            .nudgeCard()
                        }
                        .buttonStyle(.plain)
                    }
                    CardList {
                        SettingsLink(icon: "bell.badge.fill", tint: .lavender, title: "Nudges", value: app.settings.settings.frequency.title) { NudgeSettingsView() }
                        RowDivider().padding(.leading, 52)
                        SettingsLink(icon: "calendar", tint: .sky, title: "Calendars", value: "Apple") { CalendarSettingsView() }
                        RowDivider().padding(.leading, 52)
                        SettingsLink(icon: "heart.fill", tint: .rose, title: "WHOOP", value: "Optional") { WhoopSettingsView() }
                        RowDivider().padding(.leading, 52)
                        SettingsLink(icon: "photo.on.rectangle", tint: .butter, title: "Photos", value: app.settings.settings.photoMode.title) { PhotoSettingsView() }
                        RowDivider().padding(.leading, 52)
                        SettingsLink(icon: "sparkles", tint: .mint, title: "Memory", value: app.settings.settings.memoryEnabled ? "On" : "Off") { MemorySettingsView() }
                    }
                    CardList {
                        SettingsLink(icon: "person.crop.circle", tint: .peach, title: "Account", value: nil) { AccountSettingsView() }
                        RowDivider().padding(.leading, 52)
                        SettingsLink(icon: "doc.text", tint: .rose, title: "Terms & Privacy", value: nil) { FullTermsView.Page() }
                    }
                    Text("Nudge \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption).foregroundStyle(Palette.inkTertiary)
                }
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.xl)
            }
            .nudgeBackground()
            .navigationTitle("Settings")
        }
    }
}

struct SettingsLink<Destination: View>: View {
    let icon: String
    let tint: Palette.Tint
    let title: String
    let value: String?
    @ViewBuilder let destination: () -> Destination
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: Space.s) {
                Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(tint.strong)
                    .frame(width: 30, height: 30).background(tint.fill, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                Text(title).font(.body).foregroundStyle(Palette.ink)
                Spacer()
                if let value, !typeSize.isAccessibilitySize { Text(value).font(.body).foregroundStyle(Palette.inkSecondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkTertiary)
            }
            .padding(.horizontal, Space.m)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A labelled toggle row with an optional explanation.
struct ToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Palette.ink)
                if let detail { Text(detail).font(.footnote).foregroundStyle(Palette.inkSecondary) }
            }
        }
        .tint(Palette.mintStrong)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) { content }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s)
                .padding(.bottom, Space.xl)
        }
        .nudgeBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Nudges

struct NudgeSettingsView: View {
    @Environment(AppModel.self) private var app
    var store: SettingsStore { app.settings }

    func binding<T>(_ kp: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: kp] }, set: { v in store.update { $0[keyPath: kp] = v } })
    }

    var body: some View {
        SettingsPage(title: "Nudges") {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("How often")
                VStack(alignment: .leading, spacing: Space.s) {
                    Picker("Frequency", selection: binding(\.frequency)) {
                        ForEach(Frequency.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.segmented)
                    Text(store.settings.frequency.explanation + " Nudge temporarily backs off when you skip or miss invitations, then gradually tries again. Your frequency setting stays the same.").font(.footnote).foregroundStyle(Palette.inkSecondary)
                        .animation(nil, value: store.settings.frequency)
                }
                .nudgeCard()
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Quiet hours")
                CardList {
                    TimeRow(title: "Starts", selection: Binding(get: { SettingsStore.date(from: store.settings.quietStart) },
                                                               set: { d in store.update { $0.quietStart = SettingsStore.hhmm(from: d) } }))
                    RowDivider()
                    TimeRow(title: "Ends", selection: Binding(get: { SettingsStore.date(from: store.settings.quietEnd) },
                                                             set: { d in store.update { $0.quietEnd = SettingsStore.hhmm(from: d) } }))
                }
                Text("No nudges during these hours, in your time zone.").font(.footnote).foregroundStyle(Palette.inkTertiary)
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Minimum free time")
                Picker("Minimum free time", selection: binding(\.minWindowMin)) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min") }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Don't interrupt")
                CardList {
                    ToggleRow(title: "Don't nudge during Focus", isOn: binding(\.respectFocus))
                    RowDivider()
                    ToggleRow(title: "Don't nudge while driving", isOn: binding(\.respectDriving))
                }
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("When I skip")
                CardList {
                    SkipChoice(title: "Send a follow-up message", selected: store.settings.skipBehavior == .message) {
                        store.update { $0.skipBehavior = .message }
                    }
                    RowDivider()
                    SkipChoice(title: "Send nothing", selected: store.settings.skipBehavior == .nothing) {
                        store.update { $0.skipBehavior = .nothing }
                    }
                }
                if store.settings.skipBehavior == .message {
                    HStack {
                        Spacer(minLength: 48)
                        Text("Can't right now, I'll call you soon!")
                            .font(.subheadline).foregroundStyle(Palette.lavenderStrong)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Palette.lavender, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    Text("A short, friendly note in your words is written for you each time.").font(.footnote).foregroundStyle(Palette.inkTertiary)
                }
            }
        }
    }
}

struct SkipChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.body).foregroundStyle(Palette.ink)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.lavenderStrong) }
            }
            .padding(.horizontal, Space.m).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Calendars

struct CalendarSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsPage(title: "Calendars") {
            HStack(spacing: Space.s) {
                Image(systemName: "lock.fill").foregroundStyle(Palette.skyStrong)
                Text("Only busy times are shared. Never event names.").font(.subheadline.weight(.medium)).foregroundStyle(Palette.skyStrong)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .nudgeCard(fill: Palette.sky)

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Apple Calendar")
                if app.availability.calendars.isEmpty && !app.availability.isAuthorized && !app.isPreview {
                    NudgeButton("Allow calendar access", kind: .primary) { Task { _ = await app.availability.requestAccess() } }
                } else {
                    CardList {
                        let cals = app.availability.calendars
                        ForEach(Array(cals.enumerated()), id: \.element.id) { i, c in
                            Toggle(isOn: Binding(get: { !app.availability.disabledCalendarIds.contains(c.id) },
                                                 set: { app.availability.setCalendar(c.id, enabled: $0) })) {
                                HStack(spacing: Space.s) {
                                    Circle().fill(Color(hex: c.colorHex)).frame(width: 10, height: 10)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.title).font(.body).foregroundStyle(Palette.ink)
                                        Text(c.source).font(.caption).foregroundStyle(Palette.inkTertiary)
                                    }
                                }
                            }
                            .tint(Palette.mintStrong)
                            .padding(.horizontal, Space.m).padding(.vertical, Space.xs + 2)
                            if i < cals.count - 1 { RowDivider() }
                        }
                    }
                    if let synced = app.availability.lastSyncedAt {
                        Text("Last synced \(synced.formatted(.relative(presentation: .named)))").font(.footnote).foregroundStyle(Palette.inkTertiary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Other calendars")
                CardList {
                    HStack(spacing: Space.s) {
                        Image(systemName: "g.circle.fill").font(.title3).foregroundStyle(Palette.inkTertiary)
                        Text("Google Calendar").font(.body).foregroundStyle(Palette.inkSecondary)
                        Spacer()
                        Pill("Coming soon", tint: .butter)
                    }
                    .padding(.horizontal, Space.m).frame(minHeight: 52)
                }
            }
        }
        .task { if !app.isPreview { await app.availability.refreshCalendars() } }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s, radix: 16) ?? 0x9AA0AE
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: Photos

struct PhotoSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmDelete = false
    var store: SettingsStore { app.settings }

    var body: some View {
        let status = app.photos.status
        SettingsPage(title: "Photos") {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Sharing on calls")
                Picker("Sharing", selection: Binding(get: { store.settings.photoMode }, set: { m in store.update { $0.photoMode = m } })) {
                    ForEach(PhotoMode.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                Text(modeExplanation).font(.footnote).foregroundStyle(Palette.inkSecondary)
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Photo index")
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(status.indexed)").font(.system(.largeTitle, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("photos from the last 30 days").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                    }
                    HStack(spacing: Space.xs) {
                        if status.excluded > 0 { Pill("\(status.excluded) excluded for safety", tint: .rose, systemImage: "shield.lefthalf.filled") }
                        if app.photos.isRunning || status.pending > 0 {
                            Pill(status.pending > 0 ? "\(status.pending) indexing" : "Checking…", tint: .sky, systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    if app.photos.isRunning || status.pending > 0 {
                        ProgressView(value: Double(status.indexed), total: Double(max(1, status.indexed + status.pending))).tint(Palette.lavenderStrong)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nudgeCard()
                CardList {
                    ToggleRow(title: "Index my photos", detail: "Only photos taken in the last 30 days, and never hidden ones.",
                              isOn: Binding(get: { store.settings.photoIndexing }, set: { v in store.update { $0.photoIndexing = v } }))
                    RowDivider()
                    ToggleRow(title: "Include screenshots", detail: "Screenshots with card numbers, codes or IDs are always excluded.",
                              isOn: Binding(get: { store.settings.includeScreenshots }, set: { v in store.update { $0.includeScreenshots = v } }))
                }
            }

            CardList {
                Button { confirmDelete = true } label: {
                    Text("Delete all indexed photos").foregroundStyle(Palette.roseStrong).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Space.m).frame(minHeight: 52)
            }
        }
        .confirmationDialog("Delete all indexed photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await app.photos.deleteAll() } }
        } message: { Text("Photos stay on your phone. Nudge just forgets them until you index again.") }
        .task { if !app.isPreview { await app.photos.refreshStatus() } }
    }

    var modeExplanation: String {
        switch store.settings.photoMode {
        case .ask: "When you mention something, a suggestion appears only for you. Tap Show to share it."
        case .auto: "Photos you mention appear right away, with two seconds to hide them."
        case .off: "No photo suggestions during calls."
        }
    }
}

// MARK: Memory

struct MemorySettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmDelete = false

    var body: some View {
        SettingsPage(title: "Memory") {
            CardList {
                ToggleRow(title: "Remember my calls", detail: "After a call, a short summary and follow-up topics are saved. If either person turns this off, nothing is saved.",
                          isOn: Binding(get: { app.settings.settings.memoryEnabled }, set: { v in app.settings.update { $0.memoryEnabled = v } }))
            }
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("All memories")
                let withMemories = app.friends.sortedFriends.filter { !(app.memory.byFriend[$0.id]?.topics.isEmpty ?? true) }
                if withMemories.isEmpty {
                    Text("Memories from your calls will be listed here, by friend.").font(.subheadline).foregroundStyle(Palette.inkSecondary).nudgeCard()
                } else {
                    ForEach(withMemories) { f in
                        VStack(alignment: .leading, spacing: Space.s) {
                            HStack(spacing: Space.s) {
                                AvatarView(user: f.user, name: f.name, size: 28)
                                Text(f.name).font(Typography.friendName).foregroundStyle(Palette.ink)
                            }
                            FlowLayout {
                                ForEach(app.memory.byFriend[f.id]?.topics ?? []) { t in
                                    TopicChip(t.title) { Task { await app.memory.deleteTopic(t, friendId: f.id) } }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .nudgeCard()
                    }
                }
            }
            CardList {
                Button { confirmDelete = true } label: {
                    Text("Delete all memories").foregroundStyle(Palette.roseStrong).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Space.m).frame(minHeight: 52)
            }
        }
        .confirmationDialog("Delete all memories?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete for everyone", role: .destructive) { Task { await app.memory.deleteAll() } }
        } message: { Text("This deletes every memory you share with every friend, for both of you.") }
        .task {
            guard !app.isPreview else { return }
            for f in app.friends.friends { await app.memory.load(friendId: f.id) }
        }
    }
}

// MARK: Account

struct AccountSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var showPhone = false

    var body: some View {
        let me = app.session.me?.user
        SettingsPage(title: "Account") {
            VStack(spacing: Space.s) {
                if let me { AvatarView(user: me.publicUser, size: 96) }
                Text(me?.displayName ?? "").font(Typography.friendNameLarge).foregroundStyle(Palette.ink)
                Text("@\(me?.handle ?? "")").font(.subheadline).foregroundStyle(Palette.inkSecondary)
            }
            .frame(maxWidth: .infinity)

            CardList {
                AccountRow(title: "Handle", value: "@\(me?.handle ?? "")", chevron: false)
                RowDivider()
                Button { nameDraft = me?.displayName ?? ""; editingName = true } label: {
                    AccountRow(title: "Name", value: me?.displayName ?? "", chevron: true)
                }.buttonStyle(.plain)
                RowDivider()
                Button { showPhone = true } label: {
                    AccountRow(title: "Phone", value: me?.phoneVerified == true ? "Verified" : "Add", chevron: true)
                }.buttonStyle(.plain)
                RowDivider()
                NavigationLink { BlockedUsersView() } label: { AccountRow(title: "Blocked", value: "", chevron: true) }.buttonStyle(.plain)
            }

            CardList {
                NavigationLink { FullTermsView.Page() } label: { AccountRow(title: "Terms & Privacy", value: "", chevron: true) }.buttonStyle(.plain)
            }

            CardList {
                Button { app.signOut() } label: {
                    Text("Sign out").foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Space.m).frame(minHeight: 52)
                RowDivider()
                Button { confirmDelete = true } label: {
                    Text("Delete account").foregroundStyle(Palette.roseStrong).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Space.m).frame(minHeight: 52)
            }
        }
        .alert("Your name", isPresented: $editingName) {
            TextField("Name", text: $nameDraft)
            Button("Save") {
                Task { if let me = try? await app.api.updateMe(MePatch(displayName: nameDraft.nonEmptyString)) { app.apply(me: me) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPhone) {
            NavigationStack { PhoneView(onDone: { showPhone = false }, fromSettings: true) }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $confirmDelete) { DeleteAccountSheet() }
    }
}

struct AccountRow: View {
    let title: String
    let value: String
    let chevron: Bool

    var body: some View {
        HStack {
            Text(title).font(.body).foregroundStyle(Palette.ink)
            Spacer()
            Text(value).font(.body).foregroundStyle(Palette.inkSecondary)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkTertiary) }
        }
        .padding(.horizontal, Space.m).frame(minHeight: 52).contentShape(Rectangle())
    }
}

struct DeleteAccountSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(Palette.roseStrong)
                .frame(width: 56, height: 56).background(Palette.rose, in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Delete your account?").font(Typography.title).foregroundStyle(Palette.ink)
                Text("This permanently removes your profile, friends, messages, memories and indexed photos. It can't be undone.")
                    .font(.body).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            VStack(spacing: Space.xs) {
                NudgeButton("Delete account", kind: .destructive, isLoading: working) {
                    Task {
                        working = true
                        try? await app.api.deleteAccount()
                        working = false
                        dismiss()
                        app.signOut()
                    }
                }
                NudgeButton("Keep my account", kind: .secondary) { dismiss() }
            }
        }
        .padding(Space.l)
        .presentationDetents([.medium])
        .presentationCornerRadius(Radius.sheet)
        .background(Palette.bg)
    }
}

struct BlockedUsersView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsPage(title: "Blocked") {
            if app.friends.blocked.isEmpty {
                Text("You haven't blocked anyone.").font(.subheadline).foregroundStyle(Palette.inkSecondary).nudgeCard()
            } else {
                CardList {
                    ForEach(Array(app.friends.blocked.enumerated()), id: \.element.id) { i, u in
                        HStack(spacing: Space.s) {
                            AvatarView(user: u, size: 36)
                            Text(u.displayName).font(.body).foregroundStyle(Palette.ink)
                            Spacer()
                            Button("Unblock") { Task { await app.friends.unblock(u.id) } }.font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, Space.m).frame(minHeight: 52)
                        if i < app.friends.blocked.count - 1 { RowDivider() }
                    }
                }
            }
        }
        .task { if !app.isPreview { await app.friends.loadBlocked() } }
    }
}

extension FullTermsView {
    /// The terms as a pushed page (Settings) rather than a sheet.
    struct Page: View {
        var body: some View {
            ScrollView { Text(FullTermsView.text).font(.callout).foregroundStyle(Palette.ink).padding(Space.margin) }
                .nudgeBackground()
                .navigationTitle("Terms & Privacy")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Time picker row that stacks label over picker at accessibility sizes.
struct TimeRow: View {
    let title: String
    @Binding var selection: Date

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).font(.body).foregroundStyle(Palette.ink).fixedSize()
                Spacer()
                DatePicker(title, selection: $selection, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(.body).foregroundStyle(Palette.ink)
                DatePicker(title, selection: $selection, displayedComponents: .hourAndMinute).labelsHidden()
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 52)
    }
}
