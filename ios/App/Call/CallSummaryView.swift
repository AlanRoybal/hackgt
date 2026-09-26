import DesignSystem
import Memory
import Models
import PhotoShare
import SwiftUI

/// MEM-6: duration + "We'll remember" chips (deletable) + the photos shown on the call.
/// Closes itself 10 s after everything has loaded, if ignored.
struct CallSummaryView: View {
    @Environment(AppModel.self) private var app
    @State private var interacted = false

    /// The outro starts once the summary has slid in (FlowContainer's move transition).
    static let presentDelay = Motion.Durations.move

    var body: some View {
        if let p = app.memory.pendingSummary {
            // Figma M19 outro: badge pops, title and meta fade up, the card rises, topic chips pop in 0.06 s apart,
            // Done springs up last at 0.95 s. Plays once.
            MotionTimeline(settlesAt: Self.presentDelay + 1.6) { beat in
                content(p, Beat(t: beat.t - Self.presentDelay, reduceMotion: beat.reduceMotion))
            }
            .nudgeBackground()
            // The countdown starts only once the summary is in (or can't come), so the summary is never cut off mid-write.
            .task(id: p.isSettled && !interacted) {
                guard !app.isPreview, p.isSettled, !interacted else { return }
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled, !interacted { app.memory.dismissSummary() }
            }
        }
    }

    private func content(_ p: MemoryStore.PendingSummary, _ beat: Beat) -> some View {
        VStack(spacing: Space.l) {
            Spacer()
            ZStack {
                Circle().fill(Palette.mint).frame(width: 96, height: 96)
                Image(systemName: "checkmark").font(.system(size: 36, weight: .semibold)).foregroundStyle(Palette.mintStrong)
            }
            .motionLayer(beat.pop(at: 0, from: 0.6, fade: 0.2))
            VStack(spacing: Space.xs) {
                Text("You talked with \(p.friendName)").font(Typography.largeTitle).displayTracking()
                    .foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                    .motionLayer(beat.fadeUp(at: 0.15))
                Text(Formatters.duration(p.durationSec)).font(.title3.monospacedDigit()).foregroundStyle(Palette.inkSecondary)
                    .motionLayer(beat.fadeUp(at: 0.25))
            }

            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "sparkles").foregroundStyle(Palette.butterStrong)
                    Text("We'll remember").font(.headline).foregroundStyle(Palette.ink)
                }
                if !p.memoryAllowed {
                    Text("Memories are off, so nothing from this call was saved.").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                } else if let s = p.summary {
                    if s.topics.isEmpty {
                        Text("Nothing to follow up on this time.").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                    } else {
                        FlowLayout {
                            ForEach(Array(s.topics.enumerated()), id: \.element.id) { i, t in
                                TopicChip(t.title) {
                                    interacted = true
                                    Task { await app.memory.deleteTopic(t, friendId: p.friendId) }
                                }
                                .motionLayer(beat.pop(at: 0.5 + 0.06 * Double(i), from: 0.6).tappable)
                            }
                        }
                    }
                    Text(s.summary).font(.subheadline).foregroundStyle(Palette.inkSecondary)
                } else if p.summaryTimedOut {
                    Text("The summary is taking longer than usual. It'll appear on \(p.friendName)'s profile.")
                        .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                } else {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("Writing a short summary…").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .nudgeCard(padding: Space.m + 4)
            .motionLayer(beat.fadeUp(at: 0.3, fade: 0.3, rise: 0.5, distance: 16))
            .padding(.horizontal, Space.margin)

            if !p.photos.isEmpty { photos(p) }

            Spacer()
            NudgeButton("Done") { app.memory.dismissSummary() }
                .motionLayer(beat.springUp(at: 0.95).tappable)
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.m)
        }
    }

    private func photos(_ p: MemoryStore.PendingSummary) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Image(systemName: "photo.on.rectangle").foregroundStyle(Palette.butterStrong)
                Text(p.photos.contains(where: \.isVideo) ? "Photos and videos you shared" : "Photos you shared").font(.headline).foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, Space.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(p.photos) { photo in
                        // Screenshot mode has no server, so its fixtures name a bundled scene instead.
                        PhotoContent(image: app.isPreview ? .placeholder(photo.shareId) : .url(photo.url))
                            .frame(width: 96, height: 128)
                            .overlay(alignment: .bottomLeading) { if photo.isVideo { VideoBadge(durationMs: nil).padding(Space.xs) } }
                            .clipShape(RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
                            .accessibilityLabel(recapLabel(photo, p))
                    }
                }
                .padding(.horizontal, Space.margin)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in interacted = true })
        }
        .transition(.opacity)
    }

    private func recapLabel(_ photo: CallPhoto, _ p: MemoryStore.PendingSummary) -> String {
        let kind = photo.isVideo ? "Video" : "Photo"
        return photo.senderId == p.friendId ? "\(kind) from \(p.friendName)" : "\(kind) you showed"
    }
}
