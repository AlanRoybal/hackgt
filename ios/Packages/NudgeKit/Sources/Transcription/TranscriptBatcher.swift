import Foundation
import Models

/// Bounded, overlapping speech windows. Revisions replace the same result and the timer
/// never restarts when new words arrive, so continuous speech cannot postpone retrieval.
public actor TranscriptBatcher {
    public typealias Send = @Sendable (TranscriptSegment) async -> Void
    private let delay: Duration
    private let send: Send
    private var pending: TranscriptSegment?
    private var timer: Task<Void, Never>?
    private var lastSent: [String: String] = [:]

    public init(delay: Duration = .milliseconds(1200), send: @escaping Send) {
        self.delay = delay
        self.send = send
    }

    public func append(_ next: TranscriptSegment) async {
        if next.isPartial != true {
            if pending?.segId == next.segId { pending = nil }
            await send(next)
            lastSent.removeValue(forKey: next.segId)
            return
        }
        guard next.text.split(whereSeparator: \.isWhitespace).count >= 5 else { return }
        var window = next
        window.text = next.text.split(whereSeparator: \.isWhitespace).suffix(48).joined(separator: " ")
        guard lastSent[next.segId] != window.text else { return }
        pending = window
        guard timer == nil else { return }
        timer = Task { [delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self.flush()
        }
    }

    public func flush() async {
        timer?.cancel()
        timer = nil
        guard let segment = pending else { return }
        pending = nil
        if lastSent.count > 32 { lastSent.removeAll() }
        lastSent[segment.segId] = segment.text
        await send(segment)
    }

    public func discard() {
        timer?.cancel()
        timer = nil
        pending = nil
        lastSent.removeAll()
    }

    public func finish() async { await flush() }
}
