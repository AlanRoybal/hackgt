import Foundation

/// Where a shared photo's pixels come from.
public enum PhotoImage: Hashable, Sendable {
    case url(URL)
    case data(Data)
    case placeholder(String) // screenshot/preview mode: an asset name
    /// A short video (local file or remote URL) with its poster frame, shown until the first frame is ready.
    case video(URL, poster: URL?)

    public var isVideo: Bool { if case .video = self { true } else { false } }
}

/// A photo currently visible in a mini window.
public struct PhotoRef: Hashable, Sendable {
    public var shareId: String
    public var senderId: String
    public var image: PhotoImage
    public var startedAt: Date
    public var durationMs: Int
    public var queueIndex: Int
    public var queueLength: Int

    public init(shareId: String, senderId: String, image: PhotoImage, startedAt: Date, durationMs: Int, queueIndex: Int = 0, queueLength: Int = 1) {
        self.shareId = shareId
        self.senderId = senderId
        self.image = image
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.queueIndex = queueIndex
        self.queueLength = queueLength
    }

    public var endsAt: Date { startedAt.addingTimeInterval(Double(durationMs) / 1000) }
}

/// What this device's mini window shows.
public enum DisplayState: Hashable, Sendable {
    case selfView
    case mine(PhotoRef)
    case other(PhotoRef)

    public var photo: PhotoRef? {
        switch self {
        case .selfView: nil
        case .mine(let p), .other(let p): p
        }
    }
}

/// SPEC REF-8. Every device runs the same function on its own state:
/// the other participant's active photo wins, then my own, then my camera.
public enum DisplayRule {
    public static func resolve(mine: PhotoRef?, other: PhotoRef?) -> DisplayState {
        if let other { return .other(other) }
        if let mine { return .mine(mine) }
        return .selfView
    }
}

/// SPEC REF-9 durations, keyed by how many items are pending including the one being offered.
public enum PhotoTiming {
    public static let maxQueue = 5
    public static let readyTimeout: TimeInterval = 1.5
    /// Longest clip that plays in a call (VID-1); the backend indexes nothing longer.
    public static let maxVideoMs = 30_000
    /// Held past the clip's end so a late first frame doesn't cut the ending, then the video dissolves away.
    public static let videoTailMs = 400

    /// A video stays up for its own length, whatever is queued behind it (VID-4).
    public static func durationMs(videoMs: Int) -> Int {
        min(max(videoMs, 1000), maxVideoMs) + videoTailMs
    }

    public static func durationMs(pendingIncludingCurrent n: Int) -> Int {
        switch n {
        case ...1: 6000
        case 2: 4500
        default: 3500
        }
    }
}
