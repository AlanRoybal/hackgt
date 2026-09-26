import DesignSystem
import Models
import Networking
import SwiftUI

struct FriendsView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var showRequests = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if app.socketStatus == .disconnected, app.friends.hasLoaded, !app.isPreview, app.config.isConfigured {
                        Banner("You're offline. Nudges will catch up.", style: .offline)
                    }
                    if !app.friends.requests.incoming.isEmpty {
                        Button { showRequests = true } label: {
                            HStack(spacing: Space.s) {
                                Image(systemName: "person.crop.circle.badge.plus").font(.headline)
                                Text(requestsLabel).font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            }
                            .foregroundStyle(Palette.skyStrong)
                            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                            .background(Palette.sky, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    if !app.friends.hasLoaded {
                        CardList { ForEach(0..<4, id: \.self) { i in SkeletonRow(index: i).padding(.horizontal, Space.m) } }
                    } else if app.friends.friends.isEmpty {
                        EmptyStateView(.friends, title: "Add your first friend",
                                       message: "Nudge finds the moments you're both free. Start with one person you'd love to talk to more.",
                                       actionTitle: "Add friends") { showAdd = true }
                            .padding(.top, Space.xxl)
                    } else {
                        FriendsList(freeNow: app.friends.freeNow, friends: app.friends.sortedFriends)
                    }
                    if let error = app.friends.error, app.friends.hasLoaded, app.friends.friends.isEmpty, !app.isPreview {
                        Banner(error, style: .warning)
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.xl)
            }
            .refreshable { await app.friends.load() }
            .nudgeBackground()
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus") }
                        .accessibilityLabel("Add friends")
                }
            }
            .navigationDestination(for: String.self) { FriendProfileView(friendId: $0) }
            .sheet(isPresented: $showAdd) { AddFriendsView() }
            .sheet(isPresented: $showRequests) { FriendRequestsView() }
            .task { if !app.isPreview { await app.friends.load() } }
            .onChange(of: app.pendingAddHandle) { _, h in if h != nil { showAdd = true } }
        }
    }

    var requestsLabel: String {
        let n = app.friends.requests.incoming.count
        return n == 1 ? "\(app.friends.requests.incoming[0].user.displayName) wants to connect" : "\(n) friend requests"
    }
}

/// Figma M09: on first load rows fade up 8 pt (0.35 s ease-out, 0.03 s apart). Live status: free rings and dots
/// breathe 100 → 45% every 2.4 s, each friend 0.3 s behind the last so they don't pulse in unison.
/// Created when friends first load, so switching tabs doesn't replay it.
struct FriendsList: View {
    let freeNow: [Friend]
    let friends: [Friend]

    private func rowIn(_ beat: Beat, _ i: Int) -> MotionLayer {
        let d = Motion.Durations.entranceSubtle
        return beat.fadeUp(at: Motion.Stagger.subtle * Double(i), fade: d, rise: d, distance: 8)
    }

    /// Keyed by the friend's place in the full list, so their Free now card and row breathe together.
    private func pulse(_ beat: Beat, _ friend: Friend) -> Double {
        guard !beat.reduceMotion else { return 1 }
        let i = friends.firstIndex { $0.id == friend.id } ?? 0
        return IdleMotion.dim(beat.t, period: Motion.Period.breathe, low: 0.45, offset: 0.3 * Double(i))
    }

    var body: some View {
        let entrance = Motion.Durations.entranceSubtle + Motion.Stagger.subtle * Double(freeNow.count + friends.count)
        MotionTimeline(settlesAt: entrance, loops: friends.contains(where: \.freeNow)) { beat in
            VStack(alignment: .leading, spacing: Space.l) {
                if !freeNow.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        SectionHeader("Free now")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.s) {
                                ForEach(Array(freeNow.enumerated()), id: \.element.id) { i, f in
                                    NavigationLink(value: f.id) { FreeNowCard(friend: f, pulse: pulse(beat, f)) }
                                        .buttonStyle(.plain)
                                        .motionLayer(rowIn(beat, i))
                                }
                            }
                        }
                        .scrollClipDisabled()
                    }
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionHeader("All friends", trailing: "\(friends.count)")
                    CardList {
                        ForEach(Array(friends.enumerated()), id: \.element.id) { i, f in
                            Group {
                                NavigationLink(value: f.id) {
                                    FriendRow(friend: f, pulse: pulse(beat, f)).padding(.horizontal, Space.m)
                                }
                                .buttonStyle(.plain)
                                if i < friends.count - 1 { RowDivider().padding(.leading, 56) }
                            }
                            .motionLayer(rowIn(beat, freeNow.count + i))
                        }
                    }
                }
            }
        }
    }
}

struct FreeNowCard: View {
    let friend: Friend
    var pulse: Double = 1
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: Space.xs) {
            AvatarView(user: friend.user, name: friend.name, size: 56, ring: true, ringOpacity: pulse)
            Text(friend.name).font(Typography.friendName).foregroundStyle(Palette.ink).lineLimit(1)
            Text(friend.freeUntil.map { "until \($0.formatted(date: .omitted, time: .shortened))" } ?? "free now")
                .font(.caption.weight(.medium)).foregroundStyle(Palette.mintStrong)
        }
        .frame(width: typeSize.isAccessibilitySize ? 220 : 104)
        .padding(.vertical, Space.m)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Add friends

struct AddFriendsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var initialSegment: Segment = .search
    var initialQuery = ""
    @State private var segment: Segment = .search
    @State private var query = ""

    enum Segment: String, CaseIterable { case search = "Search", contacts = "Contacts", invite = "Invite" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    Picker("Add by", selection: $segment) {
                        ForEach(Segment.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)

                    switch segment {
                    case .search:
                        TextField("Search by handle", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(NudgeTextFieldStyle())
                            .onChange(of: query) { _, q in app.friends.search(q) }
                        if query.count >= 2 && app.friends.searchResults.isEmpty {
                            Text("No one with that handle yet.").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                        } else if !app.friends.searchResults.isEmpty {
                            UserResultsList(results: app.friends.searchResults)
                        }
                    case .contacts:
                        if app.friends.contactMatches.isEmpty {
                            EmptyStateView(.contacts, title: "No contacts on Nudge yet",
                                           message: "Invite them with your link, or check back later.",
                                           actionTitle: "Check contacts") { Task { await app.friends.matchContacts() } }
                                .padding(.top, Space.l)
                        } else {
                            SectionHeader("\(app.friends.contactMatches.count) of your contacts use Nudge")
                            UserResultsList(results: app.friends.contactMatches)
                        }
                    case .invite:
                        InviteCard()
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.s)
            }
            .nudgeBackground()
            .navigationTitle("Add friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                segment = initialSegment
                if !initialQuery.isEmpty { query = initialQuery }
                if let h = app.pendingAddHandle {
                    query = h
                    segment = .search
                    app.friends.search(h)
                    app.pendingAddHandle = nil
                }
            }
        }
    }
}

struct InviteCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let handle = app.session.me?.user.handle ?? "you"
        VStack(spacing: Space.m) {
            QRCodeView(text: "nudge://add/\(handle)").frame(width: 180, height: 180)
                .padding(Space.m)
                .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            VStack(spacing: Space.xxs) {
                Text("@\(handle)").font(Typography.title).foregroundStyle(Palette.ink)
                Text("Friends can scan this or tap your link to add you.").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            SwiftUI.ShareLink(item: ShareLinkText.text(handle)) {
                Label("Share your link", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(NudgeButtonStyle(.primary))
        }
        .frame(maxWidth: .infinity)
        .nudgeCard(padding: Space.l)
    }
}

import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let img = Self.make(text) {
            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                .accessibilityLabel("QR code for your Nudge link")
        }
    }

    static func make(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: Requests

struct FriendRequestsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if !app.friends.requests.incoming.isEmpty {
                        SectionHeader("Incoming")
                        CardList {
                            let list = app.friends.requests.incoming
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                                HStack(spacing: Space.s) {
                                    AvatarView(user: r.user, size: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.user.displayName).font(Typography.friendName).foregroundStyle(Palette.ink)
                                        Text("@\(r.user.handle) · \(r.createdAt.formatted(.relative(presentation: .named)))")
                                            .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                                    }
                                    Spacer()
                                    Button { Task { await app.friends.decline(r.user.id) } } label: {
                                        Image(systemName: "xmark").font(.footnote.weight(.bold))
                                    }
                                    .buttonStyle(NudgeButtonStyle(.secondary, size: .small, fullWidth: false))
                                    .accessibilityLabel("Decline")
                                    NudgeButton("Accept", kind: .accept, size: .small, fullWidth: false) {
                                        Task { await app.friends.accept(r.user.id) }
                                    }
                                }
                                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                                if i < list.count - 1 { RowDivider() }
                            }
                        }
                    }
                    if !app.friends.requests.outgoing.isEmpty {
                        SectionHeader("Sent")
                        CardList {
                            let list = app.friends.requests.outgoing
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                                HStack(spacing: Space.s) {
                                    AvatarView(user: r.user, size: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.user.displayName).font(Typography.friendName).foregroundStyle(Palette.ink)
                                        Text("@\(r.user.handle)").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                                    }
                                    Spacer()
                                    Button("Cancel") { Task { await app.friends.cancel(r.user.id) } }
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                                }
                                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                                if i < list.count - 1 { RowDivider() }
                            }
                        }
                    }
                    if app.friends.requests.incoming.isEmpty && app.friends.requests.outgoing.isEmpty {
                        EmptyStateView(.friends, title: "No requests", message: "When someone adds you, they'll show up here.").padding(.top, Space.xxl)
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.s)
            }
            .nudgeBackground()
            .navigationTitle("Friend requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
