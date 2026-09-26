@preconcurrency import AVFoundation
import Foundation
import os

/// A final (non-partial) transcript result for this device's own microphone.
public struct FinalSegment: Sendable, Hashable {
    public var id: String
    public var text: String
    public var startMs: Int
    public var endMs: Int

    public init(id: String, text: String, startMs: Int, endMs: Int) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// Parses Transcribe `TranscriptEvent` JSON payloads into final segments.
public enum TranscriptParser {
    struct Payload: Decodable {
        struct Transcript: Decodable { let Results: [Result] }
        struct Result: Decodable {
            let ResultId: String
            let StartTime: Double
            let EndTime: Double
            let IsPartial: Bool
            let Alternatives: [Alternative]
        }
        struct Alternative: Decodable { let Transcript: String }
        let Transcript: Transcript
    }

    public static func finals(from message: EventStreamMessage) throws -> [FinalSegment] {
        if message.header(":message-type") == "exception" {
            throw TranscriptionError.service(String(decoding: message.payload, as: UTF8.self))
        }
        guard message.header(":event-type") == "TranscriptEvent" else { return [] }
        let p = try JSONDecoder().decode(Payload.self, from: message.payload)
        return p.Transcript.Results.compactMap { r in
            guard !r.IsPartial, let text = r.Alternatives.first?.Transcript.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return FinalSegment(id: r.ResultId, text: text, startMs: Int(r.StartTime * 1000), endMs: Int(r.EndTime * 1000))
        }
    }
}

/// Streams 16 kHz mono PCM to Amazon Transcribe over a SigV4-presigned WebSocket (SPEC REF-1, D-5).
public actor TranscribeStreamClient {
    private let region: String
    private let credentials: @Sendable () async throws -> AWSCredentials
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<FinalSegment>.Continuation?
    private let log = Logger(subsystem: "app.nudge", category: "transcribe")

    public static let sampleRate = 16_000

    public init(region: String, credentials: @escaping @Sendable () async throws -> AWSCredentials) {
        self.region = region
        self.credentials = credentials
    }

    public static func streamURL(region: String) -> URL {
        var c = URLComponents()
        c.scheme = "wss"
        c.host = "transcribestreaming.\(region).amazonaws.com"
        c.port = 8443
        c.path = "/stream-transcription-websocket"
        c.queryItems = [
            URLQueryItem(name: "language-code", value: "en-US"),
            URLQueryItem(name: "media-encoding", value: "pcm"),
            URLQueryItem(name: "sample-rate", value: String(sampleRate)),
        ]
        return c.url!
    }

    public func start() async throws -> AsyncStream<FinalSegment> {
        let creds = try await credentials()
        let url = SigV4.presign(url: Self.streamURL(region: region), credentials: creds, region: region,
                                service: "transcribe", date: Date(), expires: 300)
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        let (stream, continuation) = AsyncStream<FinalSegment>.makeStream()
        self.continuation = continuation
        receiveTask = Task { await self.receiveLoop(task) }
        return stream
    }

    public func send(pcm: Data) async {
        guard let socket else { return }
        do { try await socket.send(.data(EventStreamMessage.audioEvent(pcm).encoded())) }
        catch { log.error("send: \(String(describing: error), privacy: .public)") }
    }

    public func stop() async {
        // An empty audio event signals end of stream.
        if let socket { try? await socket.send(.data(EventStreamMessage.audioEvent(Data()).encoded())) }
        try? await Task.sleep(for: .milliseconds(300))
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation?.finish()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard case .data(let data) = message else { continue }
                let decoded = try EventStreamMessage.decode(data)
                for seg in try TranscriptParser.finals(from: decoded) { continuation?.yield(seg) }
            } catch {
                log.error("receive: \(String(describing: error), privacy: .public)")
                break
            }
        }
        continuation?.finish()
    }
}

/// Taps the microphone and emits ~100 ms chunks of 16 kHz mono Int16 PCM.
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(TranscribeStreamClient.sampleRate), channels: 1, interleaved: true)!

    public init() {}

    public func start(onChunk: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw TranscriptionError.microphoneUnavailable }
        converter = AVAudioConverter(from: format, to: target)
        let targetFormat = target
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [weak self] tapBuffer, _ in
            guard let self, let converter = self.converter else { return }
            nonisolated(unsafe) let buffer = tapBuffer
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / format.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            let fed = OnceFlag()
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed.value { status.pointee = .noDataNow; return nil }
                fed.value = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let ch = out.int16ChannelData else { return }
            onChunk(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Single-threaded flag for AVAudioConverter's synchronous input block.
private final class OnceFlag: @unchecked Sendable { var value = false }
