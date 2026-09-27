import DesignSystem
import Models
import SwiftUI

/// Screen 12: nickname, Call now / Message, memories (topics + summaries), history, remove/block.
struct FriendProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let friendId: String
    @State private var editingNickname = false
    @State private var nicknameDraft = ""
    @State private var confirmRemove = false
    @State private var confirmBlock = false
    @State private var calling = false

    var friend: Friend? { app.friends.friend(id: friendId) }
    var memories: Memories { app.memory.byFriend[friendId] ?? Memories() }
    var history: [CallHistoryEntry] { app.memory.callHistory[friendId] ?? [] }

    var body: some View {
        ScrollView {
            if let friend {
                VStack(spacing: Space.l) {
                    header(friend)
                    AdaptiveStack(spacing: Space.s) {
                        NudgeButton("Call now", systemImage: "video.fill", kind: .accept, isLoading: calling) {
                            Task { calling = true; await app.callNow(friend); calling = false }
                        }
                        NudgeButton("Message", systemImage: "bubble.left.fill", kind: .secondary) { app.openThread(friend.id) }
                    }
                    memoriesSection(friend)
                    historySection
                    dangerZone(friend)
                }
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.xl)
            }
        }
        .nudgeBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task { if !app.isPreview { await app.memory.load(friendId: friendId) } }
        .alert("Nickname", isPresented: $editingNickname) {
            TextField("e.g. Mom", text: $nicknameDraft)
            Button("Save") { Task { await app.friends.setNickname(nicknameDraft, for: friendId) } }
            Button("Clear", role: .destructive) { Task { await app.friends.setNickname(nil, for: friendId) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only you see this. Nudges and calls will use it.")
        }
        .confirmationDialog("Remove \(friend?.name ?? "friend")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await app.friends.remove(friendId); dismiss() } }
        } message: { Text("You'll stop getting nudges with each other. Your shared memories are deleted.") }
        .confirmationDialog("Block \(friend?.name ?? "friend")?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await app.friends.block(friendId); dismiss() } }
        } message: { Text("They won't be able to find you or send you requests.") }
    }

    func header(_ f: Friend) -> some View {
        VStack(spacing: Space.s) {
            AvatarView(user: f.user, name: f.name, size: AvatarSize.hero, ring: f.freeNow)
            VStack(spacing: Space.xxs) {
                Button {
                    nicknameDraft = f.nickname ?? ""
                    editingNickname = true
                } label: {
                    HStack(spacing: Space.xs) {
                        Text(f.name).font(Typography.friendNameLarge).foregroundStyle(Palette.ink)
                        Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.inkTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit nickname")
                Text(f.nickname == nil ? "@\(f.user.handle)" : "\(f.user.displayName) · @\(f.user.handle)")
                    .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                if f.nickname != nil {
                    Text("Only you see the nickname").font(.caption).foregroundStyle(Palette.inkTertiary)
                }
            }
            if f.freeNow {
                Pill(f.freeUntilText().map { "Free until \($0)" } ?? "Free now", tint: .mint, systemImage: "circle.fill")
            }
        }
        .padding(.top, Space.s)
    }

    @ViewBuilder
    func memoriesSection(_ f: Friend) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Memories")
            if memories.topics.isEmpty && memories.summaries.isEmpty {
                HStack(spacing: Space.m) {
                    Illustration(.memories).frame(width: 64, height: 48)
                    Text("After your calls, the things worth following up on show up here.")
                        .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                }
                .nudgeCard()
            } else {
                VStack(alignment: .leading, spacing: Space.m) {
                    if !memories.topics.isEmpty {
                        FlowLayout {
                            ForEach(memories.topics.filter { $0.status != .dismissed }) { t in
                                TopicChip(t.title) { Task { await app.memory.deleteTopic(t, friendId: f.id) } }
                            }
                        }
                    }
                    ForEach(memories.summaries) { s in
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            HStack {
                                Text(s.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                                Text("· \(Formatters.duration(s.durationSec))").font(.footnote).foregroundStyle(Palette.inkTertiary)
                                Spacer()
                                Menu {
                                    Button("Delete for both of you", systemImage: "trash", role: .destructive) {
                                        Task { await app.memory.deleteSummary(s.callId, friendId: f.id) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").foregroundStyle(Palette.inkTertiary).frame(width: 44, height: 32).contentShape(Rectangle())
                                }
                                .accessibilityLabel("Summary options")
                            }
                            Text(s.summary).font(.subheadline).foregroundStyle(Palette.ink)
                        }
                        if s.id != memories.summaries.last?.id { RowDivider(inset: 0) }
                    }
                    Text("Deleting a memory removes it for both of you.").font(.caption).foregroundStyle(Palette.inkTertiary)
                }
                .nudgeCard()
            }
        }
    }

    @ViewBuilder
    var historySection: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Calls")
                CardList {
                    ForEach(Array(history.prefix(5).enumerated()), id: \.element.id) { i, c in
                        HStack {
                            Image(systemName: "video.fill").font(.footnote).foregroundStyle(Palette.mintStrong)
                            Text(c.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(Palette.ink)
                            Spacer()
                            Text(Formatters.duration(c.durationSec)).font(.subheadline).foregroundStyle(Palette.inkSecondary)
                        }
                        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                        if i < min(history.count, 5) - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    func dangerZone(_ f: Friend) -> some View {
        CardList {
            DestructiveRow("Remove friend") { confirmRemove = true }
            RowDivider()
            DestructiveRow("Block") { confirmBlock = true }
        }
    }
}

enum Formatters {
    static func duration(_ sec: Int) -> String {
        if sec < 60 { return "\(sec) sec" }
        let m = sec / 60
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    static func clock(_ sec: Int) -> String {
        String(format: "%d:%02d", sec / 60, sec % 60)
    }
}
