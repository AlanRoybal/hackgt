import Foundation

/// Shared by the audio callback and stream sender. Silence keeps the stream alive while muted.
public final class SpeechMuteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false
    public init() {}
    public func setMuted(_ value: Bool) {
        lock.lock()
        muted = value
        lock.unlock()
    }
    public func filter(_ pcm: Data) -> Data {
        lock.lock()
        let silence = muted
        lock.unlock()
        return silence ? Data(count: pcm.count) : pcm
    }
}
