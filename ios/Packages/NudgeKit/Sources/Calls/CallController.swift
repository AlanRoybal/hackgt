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
    public private(set) var queuedSuggestions: [PhotoSuggestion] = []
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
    fileprivate var sessionGeneration = UUID()
    private var audioStartTask: Task<Void, Error>?
    private var audioStartReturned = false
    private var audioConnected = false
    private var pendingMuteChange = false
    private var muteRestoreTask: Task<Void, Never>?
    private var ending = false
    private var transcriptEpoch = 0
    private var mic: MicCapture?
    private var transcriptTask: Task<Void, Never>?
    private var transcriptBatcher: TranscriptBatcher?
    private var ownTranscribeRunning = false
    private var suggestionTimer: Task<Void, Never>?
    private var autoShownTimer: Task<Void, Never>?
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
        guard !ending, !isActive else { return }
        sessionGeneration = UUID()
        let generation = sessionGeneration
        audioStartReturned = false
        audioConnected = false
        pendingMuteChange = false
        self.callId = callId
        phase = .connecting
        startedAt = nil
        endedAt = nil
        // Someone who tapped "Not now" on the mic/camera primer is asked here, at the moment it matters.
        log.notice("join \(callId, privacy: .public): mic=\(AVAudioApplication.shared.recordPermission.rawValue, privacy: .public)")
        guard await Self.ensureMicrophone() else {
            log.error("join blocked: microphone permission denied")
            self.error = "Nudge needs the microphone for calls. Turn it on in Settings."
            await leave()
            return
        }
        guard sessionGeneration == generation, isActive else { return }
        let camera = await Self.ensureCamera() // camera off is fine; the call continues audio-only
        log.notice("join: permissions ok, camera=\(camera, privacy: .public)")
        do {
            let join = try await api.join(callId: callId)
            guard sessionGeneration == generation, isActive else { return }
            peer = join.peer
            peerName = join.peerName
            peerAttendeeId = join.peerAttendeeId
            let config = try ChimeConfig.make(meeting: join.meeting, attendee: join.attendee)
            let session = DefaultMeetingSession(configuration: config, logger: ConsoleLogger(name: "Chime", level: .ERROR))
            self.session = session
            let bridge = ChimeBridge(owner: self, generation: generation)
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
            let startup = Task.detached(priority: .userInitiated) {
                try box.value.start(audioVideoConfiguration: configBox.value)
            }
            audioStartTask = startup
            try await startup.value
            log.notice("join: Chime start returned")
            guard sessionGeneration == generation, isActive else { return }
            audioStartTask = nil
            audioStartReturned = true
            restoreMuteWhenReady()
            routeAudioToSpeaker()
            try? session.audioVideo.startLocalVideo()
            session.audioVideo.startRemoteVideo()
            setUpPhotos(callId: callId)
            await startTranscription(callId: callId)
        } catch {
            guard sessionGeneration == generation, isActive else { return }
            log.error("join failed: \(String(describing: error), privacy: .public)")
            self.error = "Couldn't connect the call."
            await leave()
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

    public func leave() async { await finishCall(notifyServer: true) }

    /// Only a server/peer end event uses this path; local errors must end the shared call too.
    public func remoteEnded() async { await finishCall(notifyServer: false) }

    private func finishCall(notifyServer: Bool) async {
        guard let callId, !ending, phase != .ended else { return }
        ending = true
        endedAt = Date()
        let duration = durationSec
        // Invalidate queued SDK callbacks and pending join continuations before stopping audio.
        sessionGeneration = UUID()
        muteRestoreTask?.cancel()
        muteRestoreTask = nil
        audioConnected = false
        audioStartReturned = false
        transcriber?.muteGate.setMuted(true)
        mic?.stop()
        mic = nil
        let stoppingSession = session
        let startup = audioStartTask
        audioStartTask = nil
        if let session {
            _ = session.audioVideo.realtimeLocalMute()
            session.audioVideo.stopLocalVideo()
            session.audioVideo.stopRemoteVideo()
            session.audioVideo.stop()
        }
        session = nil
        bridge = nil
        localTileId = nil
        remoteTileId = nil
        phase = .ended
        clearSuggestions()
        autoShown = nil
        autoShownTimer?.cancel()
        photos?.reset()
        try? FileManager.default.removeItem(at: Self.clipDirectory)
        // End the server meeting concurrently with transcription cleanup, not after it.
        async let serverEnd: Void = notifyServer ? endServerCall(callId) : ()
        await stopTranscription()
        // If stop raced start(), the SDK may have ignored stop while still initializing.
        // Do not permit a replacement call until that startup has finished and been stopped.
        if let startup {
            _ = try? await startup.value
            stoppingSession?.audioVideo.stop()
        }
        await serverEnd
        ending = false
        onEnded?(callId, duration)
    }

    private func endServerCall(_ id: String) async {
        do { try await api.endCall(id) }
        catch { log.error("end call request failed: \(String(describing: error), privacy: .public)") }
    }

    // MARK: Controls

    public func toggleMute() { setMuted(!isMuted) }

    public func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        if audioStartReturned && audioConnected, let av = session?.audioVideo {
            let success = muted ? av.realtimeLocalMute() : av.realtimeLocalUnmute()
            guard success else {
                error = muted ? "Couldn't mute the call. Please end it and try again." : "Couldn't unmute. Your microphone is still muted."
                log.error("Call audio mute change failed")
                return
            }
        }
        pendingMuteChange = !(audioStartReturned && audioConnected)
        isMuted = muted
        transcriber?.muteGate.setMuted(muted)
        transcriptEpoch += 1
        let oldBatcher = transcriptBatcher
        transcriptBatcher = nil
        Task { await oldBatcher?.discard() }
        if muted {
            clearSuggestions()
        }
    }

    /// Wait for both start() and the SDK's connected callback. Default unmuted audio needs no reset.
    private func restoreMuteWhenReady() {
        guard audioStartReturned, audioConnected, isActive, isMuted || pendingMuteChange else { return }
        muteRestoreTask?.cancel()
        let generation = sessionGeneration
        muteRestoreTask = Task { [weak self] in
            for attempt in 0..<3 {
                guard let self, !Task.isCancelled, self.sessionGeneration == generation,
                      self.isActive, self.isMuted || self.pendingMuteChange else { return }
                let applied = self.isMuted ? self.session?.audioVideo.realtimeLocalMute() : self.session?.audioVideo.realtimeLocalUnmute()
                if applied == true { self.pendingMuteChange = false; return }
                self.log.notice("mute restore retry \(attempt + 1)")
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard let self, self.sessionGeneration == generation, self.isActive, self.isMuted || self.pendingMuteChange else { return }
            self.error = "Couldn't restore mute. Ending the call."
            self.muteRestoreTask = nil
            await self.leave()
        }
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

    /// Suggestions wait in arrival order; a new result never replaces an unanswered card.
    public func receive(suggestion s: PhotoSuggestion) {
        guard isActive, s.callId == callId, photoMode != .off, !isMuted else { return }
        guard suggestion?.photoId != s.photoId,
              !queuedSuggestions.contains(where: { $0.photoId == s.photoId || $0.id == s.id }) else { return }
        // Do not let an automatic result jump ahead of an outstanding manual decision.
        if s.auto && photoMode == .auto && suggestion == nil && queuedSuggestions.isEmpty {
            showSuggestion(s)
            autoShown = s
            autoShownTimer?.cancel()
            autoShownTimer = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { autoShown = nil }
            }
        } else {
            // Bound the wait below thumbnail URL expiry; preserve the active card and oldest requests.
            guard queuedSuggestions.count < 10 else { return }
            queuedSuggestions.append(s)
            presentNextSuggestion()
        }
    }

    private func presentNextSuggestion() {
        guard suggestion == nil, !queuedSuggestions.isEmpty, isActive, !isMuted, photoMode != .off else { return }
        let next = queuedSuggestions.removeFirst()
        suggestion = next
        suggestionTimer?.cancel()
        suggestionTimer = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            advanceSuggestion(expectedID: next.id)
        }
    }

    /// Shared by actions and expiry. An old timer or double tap cannot consume the next card.
    func advanceSuggestion(expectedID: String) {
        guard suggestion?.id == expectedID else { return }
        suggestionTimer?.cancel()
        suggestionTimer = nil
        suggestion = nil
        presentNextSuggestion()
    }

    private func clearSuggestions() {
        suggestionTimer?.cancel()
        suggestionTimer = nil
        suggestion = nil
        queuedSuggestions.removeAll()
    }

    public func showSuggestion(_ s: PhotoSuggestion) {
        guard isActive, !isMuted, s.callId == callId,
              suggestion?.id == s.id || (s.auto && photoMode == .auto && suggestion == nil) else { return }
        if s.isVideo, let videoUrl = s.videoUrl {
            photos?.share(OutgoingPhoto(photoId: s.photoId, suggestionId: s.suggestionId,
                                        image: .video(videoUrl, poster: s.thumbUrl), videoMs: s.durationMs))
        } else {
            photos?.share(OutgoingPhoto(photoId: s.photoId, suggestionId: s.suggestionId, image: .url(s.thumbUrl)))
        }
        advanceSuggestion(expectedID: s.id)
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
        guard suggestion?.id == dismissed.id else { return }
        advanceSuggestion(expectedID: dismissed.id)
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
            guard self.callId == callId, isActive else { await client.stop(); return }
            let gate = client.muteGate
            gate.setMuted(isMuted)
            let mic = MicCapture()
            try mic.start { chunk in
                // Filter at capture too: a queued chunk recorded while muted must stay silent after unmute.
                let pcm = gate.filter(chunk)
                Task { await client.send(pcm: pcm) }
            }
            self.mic = mic
            self.transcriber = client
            ownTranscribeRunning = true
            transcriptTask = Task {
                for await seg in stream {
                    guard !isMuted, self.callId == callId, isActive else { continue }
                    var t = TranscriptSegment(callId: callId, segId: seg.id, text: seg.text, startMs: seg.startMs, endMs: seg.endMs,
                                              clientTs: Int64(Date().timeIntervalSince1970 * 1000))
                    t.isPartial = seg.isPartial
                    await makeTranscriptBatcher().append(t)
                }
                await transcriptBatcher?.flush()
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
        guard !isMuted, isActive, !ownTranscribeRunning, let callId, attendeeId != peerAttendeeId else { return }
        let t = TranscriptSegment(callId: callId, segId: resultId, text: text, startMs: Int(startMs), endMs: Int(endMs),
                                  clientTs: Int64(Date().timeIntervalSince1970 * 1000))
        let batcher = makeTranscriptBatcher()
        Task { await batcher.append(t) }
    }

    private func makeTranscriptBatcher() -> TranscriptBatcher {
        if let transcriptBatcher { return transcriptBatcher }
        let epoch = transcriptEpoch
        let batcher = TranscriptBatcher { [weak self] segment in
            await self?.sendTranscript(segment, epoch: epoch)
        }
        transcriptBatcher = batcher
        return batcher
    }

    private func sendTranscript(_ segment: TranscriptSegment, epoch: Int) async {
        guard !isMuted, isActive, transcriptEpoch == epoch, callId == segment.callId else { return }
        try? await socket?.send(.transcript(segment))
    }

    // MARK: Chime callbacks

    func audioStarted(reconnecting: Bool) {
        guard isActive else { return }
        audioConnected = true
        restoreMuteWhenReady()
        phase = .connected
        if startedAt == nil { startedAt = Date() }
        // Chime recreates its audio unit after a network reconnect, which resets this route.
        routeAudioToSpeaker()
    }

    func audioConnecting(reconnecting: Bool) {
        guard isActive else { return }
        audioConnected = false
        phase = reconnecting ? .reconnecting : .connecting
    }

    func audioStopped() {
        let generation = sessionGeneration
        Task {
            guard sessionGeneration == generation else { return }
            await leave()
        }
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
                        autoShown: PhotoSuggestion? = nil, display: DisplayState = .selfView, callId: String? = nil) {
        self.callId = callId
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
    let generation: UUID
    init(owner: CallController, generation: UUID) { self.owner = owner; self.generation = generation }

    private func main(_ body: @escaping @MainActor (CallController) -> Void) {
        let generation = generation
        Task { @MainActor [weak owner] in
            if let owner, owner.sessionGeneration == generation { body(owner) }
        }
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
