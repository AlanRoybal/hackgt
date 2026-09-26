import DesignSystem
import SwiftUI

/// ACC-2: must accept before anything else. Plain-language summary, full text one tap away.
struct TermsView: View {
    @Environment(AppModel.self) private var app
    @State private var showFull = false
    @State private var working = false

    struct Point: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Palette.Tint
        let title: String
        let body: String
    }

    let points = [
        Point(icon: "calendar", tint: .sky, title: "We see when you're busy, not what you're doing",
              body: "Only busy times from your calendar are shared. Event names never leave your phone."),
        Point(icon: "photo.on.rectangle", tint: .butter, title: "Your last 30 days of photos are analyzed",
              body: "So the ones you mention can appear on a call. A photo is only shown after you choose to show it."),
        Point(icon: "waveform", tint: .lavender, title: "Calls are transcribed by AI",
              body: "For both people on the call, so photos can appear and follow-ups can be remembered. Transcripts are deleted within a day."),
        Point(icon: "trash", tint: .rose, title: "You can delete anything, anytime",
              body: "Memories, photos, or your whole account, from Settings."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Before we start").font(Typography.largeTitle).displayTracking().foregroundStyle(Palette.ink)
                    Text("Here's what Nudge does with your information, in plain words.")
                        .font(.body).foregroundStyle(Palette.inkSecondary)
                }
                .padding(.top, Space.xl)

                VStack(spacing: Space.s) {
                    ForEach(points) { p in
                        HStack(alignment: .top, spacing: Space.m) {
                            IconTile(p.icon, tint: p.tint, size: AvatarSize.medium)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(p.title).font(.headline).foregroundStyle(Palette.ink)
                                Text(p.body).font(.subheadline).foregroundStyle(Palette.inkSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .nudgeCard()
                    }
                }

                Button("Read the full Terms and Privacy notice") { showFull = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.lavenderStrong)
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, 120)
        }
        .nudgeBackground()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.xs) {
                NudgeButton("I agree", isLoading: working) {
                    Task {
                        working = true
                        defer { working = false }
                        let version = app.session.me?.currentTosVersion ?? "1"
                        if let me = try? await app.api.acceptTos(version: version) { app.apply(me: me) }
                    }
                }
                Text("Both people on every call have agreed to these terms.")
                    .font(.caption).foregroundStyle(Palette.inkTertiary)
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.s)
            .background(Palette.bg)
        }
        .sheet(isPresented: $showFull) { FullTermsView().nudgeSheet() }
    }
}

struct FullTermsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(Self.text)
                    .font(.callout)
                    .foregroundStyle(Palette.ink)
                    .padding(Space.margin)
            }
            .nudgeBackground()
            .navigationTitle("Terms & Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    static let text = """
    Nudge Terms of Service and Privacy Notice (draft v1 — to be reviewed by counsel before public launch)

    1. Calendar availability. Nudge reads your device calendars to compute busy time blocks for the next seven days. Only start and end times of busy blocks are uploaded. Event titles, locations, attendees and notes are never uploaded.

    2. Photos. With your permission, Nudge uploads reduced-size copies (1024 px) of photos taken in the last 30 days. They are analyzed by automated systems (Amazon Rekognition and Amazon Bedrock) to exclude unsafe or sensitive images and to make them searchable. Copies older than 30 days are deleted automatically. A photo is only shown to another person when you choose to show it, or when you turn on Automatic sharing.

    3. Call transcription. During calls, audio from each participant's microphone is transcribed by Amazon Transcribe. By accepting these terms you consent to your speech being transcribed on every call, and you acknowledge that every other Nudge user has accepted the same. Transcripts are used to find photos you mention and to create call memories, and are deleted within 24 hours.

    4. Memories. After a call, an AI model writes a short summary and a list of topics. Memories belong to both people on the call; either person can delete any memory, which deletes it for both. You can turn memories off in Settings; if either person has them off, nothing is saved.

    5. Contacts. If you choose to find friends from contacts, phone numbers are normalized and hashed on your device. Only the hashes are sent, and they are not stored.

    6. Deletion. You can delete your photos, memories, or account at any time in Settings. Deleting your account removes all of your data.
    """
}
