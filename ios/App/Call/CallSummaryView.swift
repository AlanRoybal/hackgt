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
    @State private var exportStatus = ExportStatus.idle

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
        let hasVideo = p.photos.contains(where: \.isVideo)
        return VStack(alignment: .leading, spacing: Space.s) {
            AdaptiveStack(spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "photo.on.rectangle").foregroundStyle(Palette.butterStrong)
                    Text(hasVideo ? "Photos and videos you shared" : "Photos you shared").font(.headline).foregroundStyle(Palette.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("Save All to Photos", systemImage: "square.and.arrow.down") { export(p.photos, callId: p.callId, to: .photos) }
                    Button("Share…", systemImage: "square.and.arrow.up") { export(p.photos, callId: p.callId, to: .shareSheet) }
                } label: {
                    Group {
                        if exportStatus == .working { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.lavenderStrong)
                    .padding(.horizontal, Space.s)
                    .frame(minWidth: 44, minHeight: 34)
                    .background(Palette.lavender, in: Capsule())
                }
                .disabled(exportStatus == .working)
                .accessibilityLabel(hasVideo ? "Save photos and videos" : "Save photos")
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
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
                            .contextMenu {
                                Button("Save to Photos", systemImage: "square.and.arrow.down") { export([photo], callId: p.callId, to: .photos) }
                                Button("Share…", systemImage: "square.and.arrow.up") { export([photo], callId: p.callId, to: .shareSheet) }
                            }
                            .accessibilityLabel(recapLabel(photo, p))
                    }
                }
                .padding(.horizontal, Space.margin)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in interacted = true })
            exportMessage.padding(.horizontal, Space.margin)
        }
        .transition(.opacity)
    }

    private func recapLabel(_ photo: CallPhoto, _ p: MemoryStore.PendingSummary) -> String {
        let kind = photo.isVideo ? "Video" : "Photo"
        return photo.senderId == p.friendId ? "\(kind) from \(p.friendName)" : "\(kind) you showed"
    }

    @ViewBuilder private var exportMessage: some View {
        switch exportStatus {
        case .saved(let count, let videos):
            Label(savedText(count: count, videos: videos), systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(Palette.inkSecondary).transition(.opacity)
        case .noAccess:
            HStack(spacing: Space.xs) {
                Text("Nudge needs permission to add to Photos.").font(.footnote).foregroundStyle(Palette.inkSecondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.footnote.weight(.semibold)).foregroundStyle(Palette.lavenderStrong)
            }
        case .failed:
            Text("Couldn't save. Check your connection and try again.").font(.footnote).foregroundStyle(Palette.roseStrong)
        case .idle, .working:
            EmptyView()
        }
    }

    private func savedText(count: Int, videos: Int) -> String {
        let photos = count - videos
        switch (photos, videos) {
        case (_, 0): return photos == 1 ? "Saved to Photos" : "Saved \(photos) photos to Photos"
        case (0, _): return videos == 1 ? "Saved to Photos" : "Saved \(videos) videos to Photos"
        default: return "Saved \(count) items to Photos"
        }
    }

    private enum Destination { case photos, shareSheet }

    /// Downloads the items, then saves them or opens the share sheet. Any export keeps the screen from auto-closing.
    private func export(_ items: [CallPhoto], callId: String, to destination: Destination) {
        interacted = true
        // Screenshot mode's photos are bundled scenes with no files behind them.
        guard !app.isPreview else { return }
        exportStatus = .working
        let memory = app.memory
        Task {
            do {
                let files = try await CallMediaExport.download(items, refresh: { await memory.refreshPhotos(callId: callId) })
                switch destination {
                case .shareSheet:
                    exportStatus = .idle
                    presentShareSheet(files)
                case .photos:
                    defer { CallMediaExport.discard(files) }
                    try await CallMediaExport.saveToPhotos(files)
                    exportStatus = .saved(count: files.count, videos: files.filter { $0.kind == .video }.count)
                }
            } catch CallMediaExport.Failure.photosAccessDenied {
                exportStatus = .noAccess
            } catch {
                exportStatus = .failed
            }
        }
    }
}

private enum ExportStatus: Equatable {
    case idle, working, saved(count: Int, videos: Int), noAccess, failed
}

/// The system share sheet, presented from UIKit so the downloaded files can be deleted once it closes,
/// whatever the person picked.
@MainActor private func presentShareSheet(_ files: [CallMediaExport.File]) {
    let sheet = UIActivityViewController(activityItems: files.map(\.url), applicationActivities: nil)
    sheet.completionWithItemsHandler = { _, _, _, _ in CallMediaExport.discard(files) }
    let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
    var top = root
    while let next = top?.presentedViewController { top = next }
    guard let top else { return CallMediaExport.discard(files) }
    sheet.popoverPresentationController?.sourceView = top.view
    top.present(sheet, animated: true)
}
