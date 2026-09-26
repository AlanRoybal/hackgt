import DesignSystem
import Memory
import Models
import SwiftUI

/// MEM-6: duration + "We'll remember" chips (deletable). Closes itself after 10 s if ignored.
struct CallSummaryView: View {
    @Environment(AppModel.self) private var app
    @State private var interacted = false

    var body: some View {
        if let p = app.memory.pendingSummary {
            VStack(spacing: Space.l) {
                Spacer()
                ZStack {
                    Circle().fill(Palette.mint).frame(width: 96, height: 96)
                    Image(systemName: "checkmark").font(.system(size: 36, weight: .semibold)).foregroundStyle(Palette.mintStrong)
                }
                VStack(spacing: Space.xs) {
                    Text("You talked with \(p.friendName)").font(Typography.largeTitle).displayTracking()
                        .foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                    Text(Formatters.duration(p.durationSec)).font(.title3.monospacedDigit()).foregroundStyle(Palette.inkSecondary)
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
                                ForEach(s.topics) { t in
                                    TopicChip(t.title) {
                                        interacted = true
                                        Task { await app.memory.deleteTopic(t, friendId: p.friendId) }
                                    }
                                }
                            }
                        }
                        Text(s.summary).font(.subheadline).foregroundStyle(Palette.inkSecondary)
                    } else {
                        HStack(spacing: Space.xs) {
                            ProgressView().controlSize(.small)
                            Text("Writing a short summary…").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nudgeCard(padding: Space.m + 4)
                .padding(.horizontal, Space.margin)

                Spacer()
                NudgeButton("Done") { app.memory.dismissSummary() }
                    .padding(.horizontal, Space.margin)
                    .padding(.bottom, Space.m)
            }
            .nudgeBackground()
            .task(id: interacted) {
                guard !app.isPreview, !interacted else { return }
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled, !interacted { app.memory.dismissSummary() }
            }
        }
    }
}
