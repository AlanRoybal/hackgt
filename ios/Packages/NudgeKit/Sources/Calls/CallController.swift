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
    private var transcriptBatcher: TranscriptBatcher?
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
        // Someone who tapped "Not now" on the mic/camera primer is asked here, at the moment it matters.
        log.notice("join \(callId, privacy: .public): mic=\(AVAudioApplication.shared.recordPermission.rawValue, privacy: .public)")
        guard await Self.ensureMicrophone() else {
            log.error("join blocked: microphone permission denied")
            self.error = "Nudge needs the microphone for calls. Turn it on in Settings."
            phase = .ended
            return
        }
        let camera = await Self.ensureCamera() // camera off is fine; the call continues audio-only
        log.notice("join: permissions ok, camera=\(camera, privacy: .public)")
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
            log.notice("join: starting Chime session")
            // start() sets up the audio unit synchronously and can block for a long time; keep it off the main actor.
            let box = UncheckedSendable(session.audioVideo)
            #if targetEnvironment(simulator)
            // The simulator's audio unit waits on the Mac's microphone permission and never starts headless.
            // Join without audio devices so meeting, video and photo data messages still run (D-300).
            let avConfig = AudioVideoConfiguration(audioDeviceCapabilities: .none)
            #else
            let avConfig = AudioVideoConfiguration(callKitEnabled: viaCallKit)
            #endif
            let configBox = UncheckedSendable(avConfig)
            try await Task.detached(priority: .userInitiated) {
                try box.value.start(audioVideoConfiguration: configBox.value)
            }.value
            log.notice("join: Chime start returned")
            routeAudioToSpeaker()
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

    static func ensureMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    static func ensureCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
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
        try? FileManager.default.removeItem(at: Self.clipDirectory)
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

    /// Video calls should play through the loudspeaker while the person is looking at the screen.
    /// Chime owns the audio-session category, so apply the route only after it has started it.
    private func routeAudioToSpeaker() {
        #if !targetEnvironment(simulator)
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            log.notice("audio routed to speaker")
        } catch {
            log.error("couldn't route audio to speaker: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    // MARK: Photos

    private func setUpPhotos(callId: String) {
        guard let me = selfId() else { return }
        let api = self.api
        let sendBox = SessionBox(session: session)
        let deps = PhotoShareController.Dependencies(
            createShare: { photoId, suggestionId in
                try await api.createShare(callId: callId, photoId: photoId, suggestionId: suggestionId).shareId
            },
            fetchMedia: { shareId, isVideo in
                let share = try await api.shareURL(callId: callId, shareId: shareId)
                if isVideo, let videoUrl = share.videoUrl {
                    // Download the whole clip before `ready` so both phones start it together.
                    return .video(try await Self.downloadClip(videoUrl, shareId: shareId), poster: share.url)
                }
                let (data, _) = try await URLSession.shared.data(from: share.url)
                return .data(data)
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
        // The server marks partial-transcript suggestions as manual even in auto mode.
        if s.auto && photoMode == .auto {
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
        if s.isVideo, let videoUrl = s.videoUrl {
            photos?.share(OutgoingPhoto(photoId: s.photoId, suggestionId: s.suggestionId,
                                        image: .video(videoUrl, poster: s.thumbUrl), videoMs: s.durationMs))
        } else {
            photos?.share(OutgoingPhoto(photoId: s.photoId, suggestionId: s.suggestionId, image: .url(s.thumbUrl)))
        }
    }

    /// Received clips live only for the call; `end` clears the folder.
    nonisolated static let clipDirectory = FileManager.default.temporaryDirectory.appending(path: "shared-clips", directoryHint: .isDirectory)

    nonisolated static func downloadClip(_ url: URL, shareId: String) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 300 else { throw URLError(.badServerResponse) }
        try FileManager.default.createDirectory(at: clipDirectory, withIntermediateDirectories: true)
        let dest = clipDirectory.appending(path: "\(shareId).mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    public func dismissSuggestion(_ dismissed: PhotoSuggestion) {
        if suggestion?.id == dismissed.id { suggestion = nil }
        Task { try? await api.dismissSuggestion(callId: dismissed.callId, suggestionId: dismissed.suggestionId) }
    }

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
            let batcher = makeTranscriptBatcher()
            transcriptTask = Task {
                for await seg in stream {
                    var t = TranscriptSegment(callId: callId, segId: seg.id, text: seg.text, startMs: seg.startMs, endMs: seg.endMs,
                                              clientTs: Int64(Date().timeIntervalSince1970 * 1000))
                    t.isPartial = seg.isPartial
                    await batcher.append(t)
                }
                await batcher.flush()
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
        await transcriptBatcher?.finish()
        transcriptBatcher = nil
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
        let batcher = makeTranscriptBatcher()
        Task { await batcher.append(t) }
    }

    private func makeTranscriptBatcher() -> TranscriptBatcher {
        if let transcriptBatcher { return transcriptBatcher }
        let socket = socket
        let batcher = TranscriptBatcher { segment in
            try? await socket?.send(.transcript(segment))
        }
        transcriptBatcher = batcher
        return batcher
    }

    // MARK: Chime callbacks

    fileprivate func audioStarted(reconnecting: Bool) {
        phase = .connected
        if startedAt == nil { startedAt = Date() }
        // Chime recreates its audio unit after a network reconnect, which resets this route.
        routeAudioToSpeaker()
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
        let deps = PhotoShareController.Dependencies(createShare: { _, _ in "" }, fetchMedia: { _, _ in .data(Data()) }, send: { _ in }, markShown: { _, _, _ in })
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


/// Chime's facade isn't annotated Sendable; the SDK documents start() as callable off the main thread.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
