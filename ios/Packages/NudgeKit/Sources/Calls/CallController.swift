import AmazonChimeSDK
import AVFoundation
import Foundation
import Models
import Networking
import Observation
import PhotoShare
import Transcription
import UIKit
import os

/// One 1:1 Chime call, plus the in-call photo pipeline (SPEC §2.4–2.5).
@MainActor
@Observable
public final class CallController {
    public enum Phase: Equatable, Sendable {
        case idle, connecting, connected, reconnecting, ended
    }

    public private(set) var phase: Phase = .idle
    public private(set) var callId: String?
    public private(set) var peerName: String = ""
    public private(set) var peer: PublicUser?
    public private(set) var isMuted = false
    public private(set) var isCameraOn = true
    public private(set) var remoteCameraOff = false
    public private(set) var poorNetwork = false
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var hasRemoteVideo = false
    public private(set) var hasLocalVideo = false
    public var suggestion: PhotoSuggestion?
    /// Automatic mode: "Showing to Mom · Hide" for 2 s.
    public private(set) var autoShown: PhotoSuggestion?
    public var error: String?

    public private(set) var photos: PhotoShareController?
    public let localVideoView = DefaultVideoRenderView()
    public let remoteVideoView = DefaultVideoRenderView()
    public var photoMode: PhotoMode = .ask

    private let api: NudgeAPI
    private let socket: EventSocket?
    private let selfId: () -> String?
    private let idToken: @Sendable () async -> String?
    private var session: DefaultMeetingSession?
    private var bridge: ChimeBridge?
    private var peerAttendeeId: String?
    private var localTileId: Int?
    private var remoteTileId: Int?
    private var transcriber: TranscribeStreamClient?
    private var mic: MicCapture?
    private var transcriptTask: Task<Void, Never>?
    private var ownTranscribeRunning = false
    private var suggestionTimer: Task<Void, Never>?
    private let log = Logger(subsystem: "app.nudge", category: "call")

    public var onEnded: ((_ callId: String, _ durationSec: Int) -> Void)?

    public init(api: NudgeAPI, socket: EventSocket?, selfId: @escaping () -> String?, idToken: @escaping @Sendable () async -> String?) {
        self.api = api
        self.socket = socket
        self.selfId = selfId
        self.idToken = idToken
        localVideoView.mirror = true
        localVideoView.contentMode = .scaleAspectFill
        remoteVideoView.contentMode = .scaleAspectFill
    }

    public var isActive: Bool { phase != .idle && phase != .ended }

    public var durationSec: Int {
        guard let startedAt else { return 0 }
        return Int((endedAt ?? Date()).timeIntervalSince(startedAt))
    }

    // MARK: Join / leave

    public func join(callId: String, viaCallKit: Bool) async {
        guard self.callId != callId || phase == .ended || phase == .idle else { return }
        self.callId = callId
        phase = .connecting
        startedAt = nil
        endedAt = nil
        do {
            let join = try await api.join(callId: callId)
            peer = join.peer
            peerName = join.peerName
            peerAttendeeId = join.peerAttendeeId
            let config = try ChimeConfig.make(meeting: join.meeting, attendee: join.attendee)
            let session = DefaultMeetingSession(configuration: config, logger: ConsoleLogger(name: "Chime", level: .ERROR))
            self.session = session
            let bridge = ChimeBridge(owner: self)
            self.bridge = bridge
            session.audioVideo.addAudioVideoObserver(observer: bridge)
            session.audioVideo.addVideoTileObserver(observer: bridge)
            session.audioVideo.addRealtimeDataMessageObserver(topic: PhotoShareMessage.topic, observer: bridge)
            session.audioVideo.addRealtimeTranscriptEventObserver?(observer: bridge)
            try session.audioVideo.start(callKitEnabled: viaCallKit)
            try? session.audioVideo.startLocalVideo()
            session.audioVideo.startRemoteVideo()
            setUpPhotos(callId: callId)
            await startTranscription(callId: callId)
        } catch {
            log.error("join failed: \(String(describing: error), privacy: .public)")
            self.error = "Couldn't connect the call."
            phase = .ended
        }
    }

    public func leave() async {
        guard let callId, phase != .ended else { return }
        await teardown()
        try? await api.endCall(callId)
        onEnded?(callId, durationSec)
    }

    /// The other side ended (WS `call.ended` or Chime session stopped).
    public func remoteEnded() async {
        guard let callId, phase != .ended else { return }
        await teardown()
        onEnded?(callId, durationSec)
    }

    private func teardown() async {
        endedAt = Date()
        phase = .ended
        suggestion = nil
        autoShown = nil
        photos?.reset()
        await stopTranscription()
        if let session {
            session.audioVideo.stopLocalVideo()
            session.audioVideo.stopRemoteVideo()
            session.audioVideo.stop()
        }
        session = nil
        bridge = nil
        localTileId = nil
        remoteTileId = nil
    }

    // MARK: Controls

    public func toggleMute() {
        guard let av = session?.audioVideo else { isMuted.toggle(); return }
        isMuted = isMuted ? !av.realtimeLocalUnmute() : av.realtimeLocalMute()
    }

    public func setMuted(_ muted: Bool) {
        if muted != isMuted { toggleMute() }
    }

    public func toggleCamera() {
        guard let av = session?.audioVideo else { isCameraOn.toggle(); return }
        if isCameraOn { av.stopLocalVideo(); isCameraOn = false } else {
            do { try av.startLocalVideo(); isCameraOn = true } catch { self.error = "Camera unavailable." }
        }
    }

    public func flipCamera() { session?.audioVideo.switchCamera() }

    // MARK: Photos

    private func setUpPhotos(callId: String) {
        guard let me = selfId() else { return }
        let api = self.api
        let sendBox = SessionBox(session: session)
        let deps = PhotoShareController.Dependencies(
            createShare: { photoId, suggestionId in
                try await api.createShare(callId: callId, photoId: photoId, suggestionId: suggestionId).shareId
            },
            fetchImage: { shareId in
                let url = try await api.shareURL(callId: callId, shareId: shareId).url
                let (data, _) = try await URLSession.shared.data(from: url)
                return data
            },
            send: { data in
                try await MainActor.run {
                    try sendBox.session?.audioVideo.realtimeSendDataMessage(topic: PhotoShareMessage.topic, data: data, lifetimeMs: PhotoShareMessage.lifetimeMs)
                }
            },
            markShown: { shareId, shownAt, durationMs in
                try? await api.markShown(callId: callId, shareId: shareId, shownAt: shownAt, durationMs: durationMs)
            }
        )
        photos = PhotoShareController(selfId: me, dependencies: deps)
    }

    /// A `photo.suggestion` event from the backend (only the speaker receives these).
    public func receive(suggestion s: PhotoSuggestion) {
        guard s.callId == callId, photoMode != .off else { return }
        if s.auto || photoMode == .auto {
            showSuggestion(s)
            autoShown = s
            suggestionTimer?.cancel()
            suggestionTimer = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { autoShown = nil }
            }
        } else {
            suggestion = s
            suggestionTimer?.cancel()
            suggestionTimer = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled, suggestion?.id == s.id { suggestion = nil }
            }
        }
    }

    public func showSuggestion(_ s: PhotoSuggestion) {
        if suggestion?.id == s.id { suggestion = nil }
        photos?.share(OutgoingPhoto(photoId: s.photoId, suggestionId: s.suggestionId, image: .url(s.thumbUrl)))
    }

    public func dismissSuggestion() { suggestion = nil }

    /// Hide pill in automatic mode, or swipe on my own photo.
    public func hideMine() {
        autoShown = nil
        photos?.cancelMine()
    }

    fileprivate func receiveData(_ data: Data, timestampMs: Int64) {
        photos?.receive(data: data, timestampMs: timestampMs)
    }

    // MARK: Transcription (REF-1)

    private func startTranscription(callId: String) async {
        do {
            let config = try await api.transcribeConfig()
            let cognito = CognitoIdentityClient(config: .init(identityPoolId: config.identityPoolId, region: config.region, providerName: config.userPoolProviderName))
            let idToken = self.idToken
            let client = TranscribeStreamClient(region: config.region) {
                guard let token = await idToken() else { throw TranscriptionError.cognito("signed out") }
                return try await cognito.credentials(idToken: token)
            }
            let stream = try await client.start()
            let mic = MicCapture()
            try mic.start { chunk in Task { await client.send(pcm: chunk) } }
            self.mic = mic
            self.transcriber = client
            ownTranscribeRunning = true
            let socket = self.socket
            transcriptTask = Task {
                for await seg in stream {
                    let t = TranscriptSegment(callId: callId, segId: seg.id, text: seg.text, startMs: seg.startMs, endMs: seg.endMs,
                                              clientTs: Int64(Date().timeIntervalSince1970 * 1000))
                    try? await socket?.send(.transcript(t))
                }
                await MainActor.run { self.ownTranscribeRunning = false }
            }
        } catch {
            ownTranscribeRunning = false
            log.error("transcription unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    private func stopTranscription() async {
        mic?.stop()
        mic = nil
        await transcriber?.stop()
        transcriber = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        ownTranscribeRunning = false
    }

    /// Fallback (D-201): if the meeting has Chime live transcription enabled and our own stream isn't
    /// running, forward our own final segments from Chime's events.
    fileprivate func receiveChimeTranscript(text: String, attendeeId: String, startMs: Int64, endMs: Int64, resultId: String) {
        guard !ownTranscribeRunning, let callId, attendeeId != peerAttendeeId else { return }
        let t = TranscriptSegment(callId: callId, segId: resultId, text: text, startMs: Int(startMs), endMs: Int(endMs),
                                  clientTs: Int64(Date().timeIntervalSince1970 * 1000))
        Task { try? await socket?.send(.transcript(t)) }
    }

    // MARK: Chime callbacks

    fileprivate func audioStarted(reconnecting: Bool) {
        phase = .connected
        if startedAt == nil { startedAt = Date() }
    }

    fileprivate func audioConnecting(reconnecting: Bool) {
        phase = reconnecting ? .reconnecting : .connecting
    }

    fileprivate func audioStopped() {
        Task { await remoteEnded() }
    }

    fileprivate func setPoorNetwork(_ poor: Bool) { poorNetwork = poor }

    fileprivate func tileAdded(tileId: Int, isLocal: Bool, isContent: Bool, paused: Bool) {
        guard !isContent, let av = session?.audioVideo else { return }
        if isLocal {
            localTileId = tileId
            av.bindVideoView(videoView: localVideoView, tileId: tileId)
            hasLocalVideo = true
        } else {
            remoteTileId = tileId
            av.bindVideoView(videoView: remoteVideoView, tileId: tileId)
            hasRemoteVideo = true
            remoteCameraOff = paused
        }
    }

    fileprivate func tileRemoved(tileId: Int) {
        if tileId == remoteTileId { remoteTileId = nil; hasRemoteVideo = false; remoteCameraOff = true }
        if tileId == localTileId { localTileId = nil; hasLocalVideo = false }
        session?.audioVideo.unbindVideoView(tileId: tileId)
    }

    fileprivate func tilePaused(tileId: Int, paused: Bool) {
        if tileId == remoteTileId { remoteCameraOff = paused }
    }

    // MARK: Preview

    public func preview(peer: PublicUser, peerName: String, phase: Phase, muted: Bool = false, cameraOn: Bool = true,
                        remoteCameraOff: Bool = false, poorNetwork: Bool = false, suggestion: PhotoSuggestion? = nil,
                        autoShown: PhotoSuggestion? = nil, display: DisplayState = .selfView) {
        self.peer = peer
        self.peerName = peerName
        self.phase = phase
        self.isMuted = muted
        self.isCameraOn = cameraOn
        self.remoteCameraOff = remoteCameraOff
        self.poorNetwork = poorNetwork
        self.suggestion = suggestion
        self.autoShown = autoShown
        self.startedAt = Date().addingTimeInterval(-754)
        let deps = PhotoShareController.Dependencies(createShare: { _, _ in "" }, fetchImage: { _ in Data() }, send: { _ in }, markShown: { _, _, _ in })
        let pc = PhotoShareController(selfId: "me", dependencies: deps)
        pc.previewDisplay(display)
        photos = pc
    }
}

/// Holds the session for a @Sendable closure; only touched on the main actor.
private final class SessionBox: @unchecked Sendable {
    weak var session: DefaultMeetingSession?
    init(session: DefaultMeetingSession?) { self.session = session }
}

/// Chime observer protocols are non-isolated Obj-C; this bridge extracts values and hops to the main actor.
private final class ChimeBridge: NSObject, AudioVideoObserver, VideoTileObserver, DataMessageObserver, TranscriptEventObserver, @unchecked Sendable {
    weak var owner: CallController?
    init(owner: CallController) { self.owner = owner }

    private func main(_ body: @escaping @MainActor (CallController) -> Void) {
        Task { @MainActor [weak owner] in if let owner { body(owner) } }
    }

    func audioSessionDidStartConnecting(reconnecting: Bool) { main { $0.audioConnecting(reconnecting: reconnecting) } }
    func audioSessionDidStart(reconnecting: Bool) { main { $0.audioStarted(reconnecting: reconnecting) } }
    func audioSessionDidDrop() { main { $0.audioConnecting(reconnecting: true) } }
    func audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) { main { $0.audioStopped() } }
    func audioSessionDidCancelReconnect() { main { $0.audioStopped() } }
    func connectionDidRecover() { main { $0.setPoorNetwork(false) } }
    func connectionDidBecomePoor() { main { $0.setPoorNetwork(true) } }
    func videoSessionDidStartConnecting() {}
    func videoSessionDidStartWithStatus(sessionStatus: MeetingSessionStatus) {}
    func videoSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {}
    func remoteVideoSourcesDidBecomeAvailable(sources: [RemoteVideoSource]) {}
    func remoteVideoSourcesDidBecomeUnavailable(sources: [RemoteVideoSource]) {}
    func cameraSendAvailabilityDidChange(available: Bool) {}

    func videoTileDidAdd(tileState: VideoTileState) {
        let id = tileState.tileId, local = tileState.isLocalTile, content = tileState.isContent
        let paused = tileState.pauseState != .unpaused
        main { $0.tileAdded(tileId: id, isLocal: local, isContent: content, paused: paused) }
    }

    func videoTileDidRemove(tileState: VideoTileState) {
        let id = tileState.tileId
        main { $0.tileRemoved(tileId: id) }
    }

    func videoTileDidPause(tileState: VideoTileState) {
        let id = tileState.tileId
        main { $0.tilePaused(tileId: id, paused: true) }
    }

    func videoTileDidResume(tileState: VideoTileState) {
        let id = tileState.tileId
        main { $0.tilePaused(tileId: id, paused: false) }
    }

    func videoTileSizeDidChange(tileState: VideoTileState) {}

    func dataMessageDidReceived(dataMessage: DataMessage) {
        let data = dataMessage.data, ts = dataMessage.timestampMs
        main { $0.receiveData(data, timestampMs: ts) }
    }

    func transcriptEventDidReceive(transcriptEvent: any TranscriptEvent) {
        guard let transcript = transcriptEvent as? Transcript else { return }
        for result in transcript.results where !result.isPartial {
            guard let alt = result.alternatives.first, let attendee = alt.items.first?.attendee.attendeeId else { continue }
            let text = alt.transcript, start = result.startTimeMs, end = result.endTimeMs, rid = result.resultId
            main { $0.receiveChimeTranscript(text: text, attendeeId: attendee, startMs: start, endMs: end, resultId: rid) }
        }
    }
}
