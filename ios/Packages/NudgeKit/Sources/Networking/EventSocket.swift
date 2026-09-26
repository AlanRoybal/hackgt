import Foundation
import Models
import os

/// The live-events WebSocket (SPEC §3.8): reconnects with backoff, pings every 30 s,
/// and re-sends the current `waiting` state after every reconnect.
public actor EventSocket {
    public enum Status: Sendable, Equatable { case disconnected, connecting, connected }

    private let url: URL
    private let tokens: any TokenProvider
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var waitingNudgeId: String?
    private var continuations: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]
    private(set) public var status: Status = .disconnected
    private let log = Logger(subsystem: "app.nudge", category: "socket")

    public init(url: URL, tokens: any TokenProvider, session: URLSession = .shared) {
        self.url = url
        self.tokens = tokens
        self.session = session
    }

    /// A fresh stream of server events. Multiple listeners are supported.
    public func events() -> AsyncStream<ServerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ServerEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func statusUpdates() -> AsyncStream<Status> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        statusContinuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStatusContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
    private func removeStatusContinuation(_ id: UUID) { statusContinuations[id] = nil }

    public func connect() {
        guard runLoop == nil else { return }
        runLoop = Task { await self.run() }
    }

    public func disconnect() {
        runLoop?.cancel()
        runLoop = nil
        pingLoop?.cancel()
        pingLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setStatus(.disconnected)
    }

    public func setWaiting(nudgeId: String?) async {
        waitingNudgeId = nudgeId
        try? await send(.waiting(nudgeId: nudgeId))
    }

    public func send(_ action: ClientAction) async throws {
        guard let task, status == .connected else { return }
        let data = try action.encoded()
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func setStatus(_ s: Status) {
        status = s
        for c in statusContinuations.values { c.yield(s) }
    }

    private func run() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            guard let token = await tokens.accessToken() else {
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "token", value: token)]
            let t = session.webSocketTask(with: comps.url!)
            task = t
            setStatus(.connecting)
            t.resume()
            do {
                // The first receive tells us if the upgrade succeeded.
                try await t.sendPing()
                setStatus(.connected)
                backoff = 1
                startPings()
                if let waitingNudgeId { try? await send(.waiting(nudgeId: waitingNudgeId)) }
                while !Task.isCancelled {
                    let message = try await t.receive()
                    handle(message)
                }
            } catch {
                log.info("socket closed: \(String(describing: error), privacy: .public)")
                if (t.closeCode == .policyViolation) || (error as NSError).code == 401 {
                    _ = await tokens.refreshAccessToken()
                }
            }
            pingLoop?.cancel()
            setStatus(.disconnected)
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }
    }

    private func startPings() {
        pingLoop?.cancel()
        pingLoop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                try? await self.send(.ping)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let event = try? ServerEvent.decode(data) else {
            log.error("undecodable event")
            return
        }
        for c in continuations.values { c.yield(event) }
    }

    /// Test hook: inject an event as if it came from the server.
    public func inject(_ event: ServerEvent) {
        for c in continuations.values { c.yield(event) }
    }
}

extension URLSessionWebSocketTask {
    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            sendPing { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}
