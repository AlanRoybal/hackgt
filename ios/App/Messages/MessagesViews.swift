import DesignSystem
import Models
import SwiftUI

struct ConversationsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: Binding(get: { app.openThreadId.map { [$0] } ?? [] },
                                      set: { app.openThreadId = $0.last })) {
            ScrollView {
                VStack(spacing: Space.l) {
                    if !app.messages.hasLoaded {
                        CardList { ForEach(0..<4, id: \.self) { i in SkeletonRow(index: i).padding(.horizontal, Space.m) } }
                    } else if app.messages.conversations.isEmpty {
                        EmptyStateView(.messages, title: "No messages yet",
                                       message: "When a nudge doesn't work out, notes like \"I'll call you soon\" land here.")
                            .padding(.top, Space.xxl)
                    } else {
                        CardList {
                            let list = app.messages.conversations
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                                NavigationLink(value: c.id) { ConversationRow(conversation: c) }.buttonStyle(.plain)
                                if i < list.count - 1 { RowDivider().padding(.leading, 56) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.xl)
            }
            .refreshable { await app.messages.loadConversations() }
            .nudgeBackground()
            .navigationTitle("Messages")
            .navigationDestination(for: String.self) { ThreadView(friendId: $0) }
            .task { if !app.isPreview { await app.messages.loadConversations() } }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: Space.s) {
            AvatarView(user: conversation.friend, name: conversation.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                AdaptiveStack(spacing: 2) {
                    Text(conversation.name).font(Typography.friendName).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    if let m = conversation.lastMessage {
                        Text(m.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                            .font(.caption).foregroundStyle(Palette.inkTertiary)
                    }
                }
                HStack(spacing: Space.xs) {
                    Text(preview).font(.subheadline).foregroundStyle(conversation.unread > 0 ? Palette.ink : Palette.inkSecondary).lineLimit(1)
                    Spacer()
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)").font(.caption2.weight(.bold)).foregroundStyle(Palette.lavenderStrong)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Palette.lavender, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
    }

    var preview: String {
        guard let m = conversation.lastMessage else { return "Say hi" }
        return m.kind == .system ? m.body : m.body
    }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var app
    let friendId: String
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only messages that arrive after the thread first shows animate in.
    @State private var animatesInserts = false

    var name: String {
        app.messages.conversations.first { $0.id == friendId }?.name ?? app.friends.friend(id: friendId)?.name ?? "Friend"
    }
    var messages: [Message] { app.messages.threads[friendId] ?? [] }
    var me: String { app.session.userId ?? "me" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.xs) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        let showTime = i == 0 || m.createdAt.timeIntervalSince(messages[i - 1].createdAt) > 3600
                        if showTime {
                            Text(m.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2.weight(.semibold)).foregroundStyle(Palette.inkTertiary)
                                .padding(.top, Space.s)
                        }
                        MessageBubble(message: m, isMine: m.senderId == me, friendName: name).id(m.id)
                            .transition(Self.bubbleIn(isMine: m.senderId == me, reduceMotion: reduceMotion))
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s)
                .animation(animatesInserts ? Motion.resolved(Motion.standard, reduceMotion: reduceMotion) : nil, value: messages.count)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last { withAnimation(Motion.move) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .nudgeBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Space.xs) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .background(Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Button {
                    let text = draft
                    draft = ""
                    Task { await app.messages.send(text, to: friendId) }
                } label: {
                    Image(systemName: "arrow.up").font(.headline).foregroundStyle(Palette.lavenderStrong)
                        .frame(width: 40, height: 40).background(Palette.lavender, in: Circle())
                }
                .disabled(draft.nonEmptyString == nil)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.xs)
            .background(Palette.bg)
        }
        .task {
            if !app.isPreview { await app.messages.loadThread(friendId: friendId) }
            animatesInserts = true
        }
        .onAppear { app.openThreadId = friendId }
    }

    /// Figma M13b: the incoming bubble fades in over 0.2 s, rising 12 pt and growing 96 → 100% from its tail corner.
    static func bubbleIn(isMine: Bool, reduceMotion: Bool) -> AnyTransition {
        let fade = AnyTransition.opacity.animation(.easeOut(duration: Motion.Durations.fade))
        guard !reduceMotion else { return .asymmetric(insertion: fade, removal: .opacity) }
        let rise = AnyTransition.modifier(active: BubbleRise(on: true, anchor: isMine ? .bottomTrailing : .bottomLeading),
                                          identity: BubbleRise(on: false, anchor: .center))
        return .asymmetric(insertion: fade.combined(with: rise), removal: .opacity)
    }
}

private struct BubbleRise: ViewModifier {
    let on: Bool
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content.scaleEffect(on ? 0.96 : 1, anchor: anchor).offset(y: on ? 12 : 0)
    }
}

struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    let friendName: String

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.body)
                .font(.caption.weight(.medium)).foregroundStyle(Palette.inkSecondary)
                .padding(.horizontal, Space.s).padding(.vertical, 6)
                .background(Palette.surfaceAlt, in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xxs)
        case .user, .autoFollowup:
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(isMine ? Palette.lavenderStrong : Palette.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(isMine ? Palette.lavender : Palette.surface,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if message.kind == .autoFollowup {
                    Label("Sent automatically", systemImage: "sparkles")
                        .font(.caption2).foregroundStyle(Palette.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
            .padding(isMine ? .leading : .trailing, 48)
        }
    }
}
