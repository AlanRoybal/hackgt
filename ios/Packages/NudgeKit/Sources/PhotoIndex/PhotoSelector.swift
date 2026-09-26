import CryptoKit
import Foundation

/// Metadata the selection rules need; built from PHAsset in production and by hand in tests.
public struct AssetDescriptor: Sendable, Hashable {
    public var localIdentifier: String
    public var creationDate: Date?
    public var isHidden: Bool
    public var isScreenshot: Bool
    public var isImage: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isVideo: Bool
    /// Seconds, for videos.
    public var duration: TimeInterval

    public init(localIdentifier: String, creationDate: Date?, isHidden: Bool = false, isScreenshot: Bool = false, isImage: Bool = true, pixelWidth: Int = 4032, pixelHeight: Int = 3024,
                isVideo: Bool = false, duration: TimeInterval = 0) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.isHidden = isHidden
        self.isScreenshot = isScreenshot
        self.isImage = isImage
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isVideo = isVideo
        self.duration = duration
    }

    public var durationMs: Int { Int((duration * 1000).rounded()) }
}

/// PHO-1 / VID-1 rules: images and short videos taken in the last 30 days, never hidden, screenshots only when enabled.
public enum PhotoSelector {
    public static let window: TimeInterval = 30 * 24 * 3600
    public static let longEdge: CGFloat = 1024
    /// Longest video that's indexed and can play in a call. Matches the backend's `MAX_VIDEO_MS`.
    public static let maxVideoDuration: TimeInterval = 30

    public static func select(_ assets: [AssetDescriptor], includeScreenshots: Bool, now: Date) -> [AssetDescriptor] {
        let cutoff = now.addingTimeInterval(-window)
        return assets.filter { a in
            guard a.isImage || isShortVideo(a), !a.isHidden, let d = a.creationDate, d >= cutoff, d <= now.addingTimeInterval(300) else { return false }
            return includeScreenshots || !a.isScreenshot
        }
    }

    public static func isShortVideo(_ a: AssetDescriptor) -> Bool {
        a.isVideo && a.duration > 0 && a.duration <= maxVideoDuration
    }

    /// Stable, non-reversible id for an asset (the local identifier never leaves the device).
    public static func assetHash(_ localIdentifier: String) -> String {
        Data(SHA256.hash(data: Data("nudge-asset:\(localIdentifier)".utf8))).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Output size for a 1024-px long edge, never upscaling.
    public static func targetSize(width: Int, height: Int, longEdge: CGFloat = longEdge) -> CGSize {
        let w = CGFloat(width), h = CGFloat(height)
        let scale = min(1, longEdge / max(w, h, 1))
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }
}
