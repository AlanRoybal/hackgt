import Foundation
import Models

/// Combines adjacent final ASR segments into one complete thought before retrieval.
/// The backend still stores each submitted item and applies its own deduplication.
public actor TranscriptBatcher {
    public typealias Send = @Sendable (TranscriptSegment) async -> Void

    private let delay: Duration
    private let send: Send
    private var pending: TranscriptSegment?
    private var timer: Task<Void, Never>?

    public init(delay: Duration = .seconds(3), send: @escaping Send) {
        self.delay = delay
        self.send = send
    }

    public func append(_ next: TranscriptSegment) async {
        if let current = pending, canMerge(current, next) {
            pending = TranscriptSegment(
                callId: current.callId,
                segId: UUID().uuidString,
                text: "\(current.text) \(next.text)",
                startMs: current.startMs,
                endMs: max(current.endMs, next.endMs),
                clientTs: next.clientTs
            )
        } else {
            await flush()
            pending = next
        }
        scheduleFlush()
    }

    public func flush() async {
        timer?.cancel()
        timer = nil
        guard let pending else { return }
        self.pending = nil
        await send(pending)
    }

    public func finish() async {
        await flush()
    }

    private func canMerge(_ current: TranscriptSegment, _ next: TranscriptSegment) -> Bool {
        current.callId == next.callId && next.startMs - current.endMs <= 2_500 && next.startMs >= current.startMs
    }

    private func scheduleFlush() {
        timer?.cancel()
        timer = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }
}
