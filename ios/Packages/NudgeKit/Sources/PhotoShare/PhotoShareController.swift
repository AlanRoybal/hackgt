import Foundation
import Observation
import os

/// Runs a `PhotoShareSession` against real side effects and publishes the mini-window state.
@MainActor
@Observable
public final class PhotoShareController {
    public struct Dependencies: Sendable {
        /// POST /calls/{id}/shares → shareId
        public var createShare: @Sendable (_ photoId: String, _ suggestionId: String?) async throws -> String
        /// GET /calls/{id}/shares/{shareId} + download the photo, or the clip to a local file for a video
        public var fetchMedia: @Sendable (_ shareId: String, _ isVideo: Bool) async throws -> PhotoImage
        /// Chime realtimeSendDataMessage
        public var send: @Sendable (_ data: Data) async throws -> Void
        /// POST /calls/{id}/shares/{shareId}/shown
        public var markShown: @Sendable (_ shareId: String, _ shownAt: Date, _ durationMs: Int) async -> Void

        public init(
            createShare: @escaping @Sendable (String, String?) async throws -> String,
            fetchMedia: @escaping @Sendable (String, Bool) async throws -> PhotoImage,
            send: @escaping @Sendable (Data) async throws -> Void,
            markShown: @escaping @Sendable (String, Date, Int) async -> Void
        ) {
            self.createShare = createShare
            self.fetchMedia = fetchMedia
            self.send = send
            self.markShown = markShown
        }
    }

    public private(set) var display: DisplayState = .selfView
    public private(set) var session: PhotoShareSession
    private let deps: Dependencies
    private var timer: Task<Void, Never>?
    private let log = Logger(subsystem: "app.nudge", category: "photoshare")
    /// Called whenever `display` changes (the call view animates on it).
    public var onDisplayChange: ((DisplayState) -> Void)?

    public init(selfId: String, dependencies: Dependencies) {
        self.session = PhotoShareSession(selfId: selfId)
        self.deps = dependencies
    }

    public func share(_ photo: OutgoingPhoto) { dispatch(.share(photo)) }
    public func cancelMine() { dispatch(.cancelMine) }
    public func reset() { dispatch(.reset) }

    public func receive(data: Data, timestampMs: Int64) {
        do {
            let m = try PhotoShareMessage.decode(data)
            dispatch(.received(ReceivedPhotoMessage(message: m, timestampMs: timestampMs)))
        } catch {
            log.error("bad photo message: \(String(describing: error), privacy: .public)")
        }
    }

    public var myQueueCount: Int { session.outgoingCount }

    private func dispatch(_ event: PhotoShareSession.Event) {
        let effects = session.handle(event, now: Date())
        let newDisplay = session.display(now: Date())
        if newDisplay != display {
            display = newDisplay
            onDisplayChange?(newDisplay)
        }
        for effect in effects { run(effect) }
        scheduleTick()
    }

    private func run(_ effect: PhotoShareSession.Effect) {
        switch effect {
        case .createShare(let photo):
            Task {
                do {
                    let shareId = try await deps.createShare(photo.id, photo.suggestionId)
                    dispatch(.shareCreated(photoId: photo.id, shareId: shareId))
                } catch {
                    dispatch(.shareFailed(photoId: photo.id))
                }
            }
        case .send(let message):
            Task {
                do { try await deps.send(try message.encoded()) }
                catch { log.error("send failed: \(String(describing: error), privacy: .public)") }
            }
        case .fetch(let shareId, _, let isVideo):
            Task {
                do {
                    let image = try await deps.fetchMedia(shareId, isVideo)
                    dispatch(.incomingLoaded(shareId: shareId, image: image))
                } catch {
                    dispatch(.incomingFailed(shareId: shareId))
                }
            }
        case .markShown(let shareId, let shownAt, let durationMs):
            Task { await deps.markShown(shareId, shownAt, durationMs) }
        case .log(let text):
            log.info("\(text, privacy: .public)")
        }
    }

    private func scheduleTick() {
        timer?.cancel()
        guard let deadline = session.nextDeadline else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 5))
            guard !Task.isCancelled else { return }
            self?.dispatch(.tick)
        }
    }

    /// Screenshot / preview support: force a display state.
    public func previewDisplay(_ state: DisplayState) { display = state }
}
