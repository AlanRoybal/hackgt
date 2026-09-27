import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import Models
import Networking
import Observation
import Photos
import UniformTypeIdentifiers
import UIKit
import os

/// Uploads the last 30 days of photos and short videos for cloud indexing (PHO-1, PHO-5, PHO-6, VID-1).
@MainActor
@Observable
public final class PhotoIndexer: NSObject {
    public private(set) var status = PhotoStatus()
    public private(set) var isRunning = false
    public private(set) var queuedThisRun = 0
    public private(set) var uploadedThisRun = 0
    public var error: String?

    private let api: NudgeAPI
    private let uploader: BackgroundUploader
    private let defaults: UserDefaults
    private var observerRegistered = false
    private var debounce: Task<Void, Never>?
    private var geocodeCache: [String: String] = [:]
    private let log = Logger(subsystem: "app.nudge", category: "photos")
    static let sentKey = "photoIndex.sentHashes"

    public var includeScreenshots = false
    public var enabled = true

    public init(api: NudgeAPI, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        self.uploader = BackgroundUploader.shared
        super.init()
    }

    public static var isAuthorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    public func requestAccess() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if s == .authorized || s == .limited { startObserving(); return true }
        return false
    }

    public func startObserving() {
        guard Self.isAuthorized, !observerRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        observerRegistered = true
    }

    public func refreshStatus() async {
        do { status = try await api.photoStatus() } catch { self.error = error.localizedDescription }
    }

    /// One incremental pass. Safe to call often; the server skips already-known hashes.
    public func run(reason: String) async {
        guard enabled, Self.isAuthorized, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let now = Date()
        let (descriptors, assets) = fetchRecent(now: now)
        let selected = PhotoSelector.select(descriptors, includeScreenshots: includeScreenshots, now: now)
        queuedThisRun = 0
        uploadedThisRun = 0

        // Remove photos that were deleted from the library or fell out of scope.
        let current = Set(selected.map { PhotoSelector.assetHash($0.localIdentifier) })
        let previouslySent = Set(defaults.stringArray(forKey: Self.sentKey) ?? [])
        for gone in previouslySent.subtracting(current) { try? await api.deletePhoto(assetHash: gone) }

        var sent = previouslySent.intersection(current)
        for batch in stride(from: 0, to: selected.count, by: 50).map({ Array(selected[$0..<min($0 + 50, selected.count)]) }) {
            var items: [PhotoUploadItem] = []
            for d in batch {
                let size = PhotoSelector.targetSize(width: d.pixelWidth, height: d.pixelHeight)
                items.append(PhotoUploadItem(assetHash: PhotoSelector.assetHash(d.localIdentifier), takenAt: d.creationDate ?? now,
                                             place: await placeName(for: assets[d.localIdentifier]), isScreenshot: d.isScreenshot,
                                             width: Int(size.width), height: Int(size.height),
                                             mediaType: d.isVideo ? .video : nil, durationMs: d.isVideo ? d.durationMs : nil))
            }
            do {
                let response = try await api.photoUploads(items)
                sent.formUnion(items.map(\.assetHash))
                queuedThisRun += response.uploads.count
                for ticket in response.uploads {
                    guard let d = batch.first(where: { PhotoSelector.assetHash($0.localIdentifier) == ticket.assetHash }),
                          let asset = assets[d.localIdentifier],
                          let file = await Self.exportJPEG(asset: asset, hash: ticket.assetHash) else { continue }
                    // A video sends its poster frame (screened and embedded) and the clip (captioned, played in calls).
                    if d.isVideo {
                        guard let videoUrl = ticket.videoUploadUrl, let clip = await Self.exportMP4(asset: asset, hash: ticket.assetHash) else { continue }
                        uploader.upload(file: clip, to: videoUrl, contentType: "video/mp4")
                    }
                    uploader.upload(file: file, to: ticket.uploadUrl)
                    uploadedThisRun += 1
                }
            } catch {
                self.error = error.localizedDescription
                log.error("upload batch failed: \(String(describing: error), privacy: .public)")
                break
            }
        }
        defaults.set(Array(sent), forKey: Self.sentKey)
        log.info("photo pass (\(reason, privacy: .public)): \(selected.count) in scope, \(self.queuedThisRun) new")
        await refreshStatus()
    }

    public func deleteAll() async {
        do {
            try await api.deleteAllPhotos()
            defaults.removeObject(forKey: Self.sentKey)
            await refreshStatus()
        } catch { self.error = error.localizedDescription }
    }

    private func fetchRecent(now: Date) -> ([AssetDescriptor], [String: PHAsset]) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND (mediaType == %d OR (mediaType == %d AND duration <= %f))",
                                        now.addingTimeInterval(-PhotoSelector.window) as NSDate, PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue, PhotoSelector.maxVideoDuration)
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var descriptors: [AssetDescriptor] = []
        var map: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = asset
            descriptors.append(AssetDescriptor(localIdentifier: asset.localIdentifier, creationDate: asset.creationDate,
                                               isHidden: asset.isHidden, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                                               isImage: asset.mediaType == .image, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                               isVideo: asset.mediaType == .video, duration: asset.duration))
        }
        return (descriptors, map)
    }

    /// Reverse-geocodes on device (cached per ~1 km cell; CLGeocoder is rate-limited).
    private func placeName(for asset: PHAsset?) async -> String? {
        guard let loc = asset?.location else { return nil }
        let key = String(format: "%.2f,%.2f", loc.coordinate.latitude, loc.coordinate.longitude)
        if let cached = geocodeCache[key] { return cached }
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return nil }
        let name = [mark.name, mark.locality, mark.administrativeArea].compactMap { $0 }.uniqued().prefix(2).joined(separator: ", ")
        geocodeCache[key] = name
        return name.isEmpty ? nil : name
    }

    static func exportJPEG(asset: PHAsset, hash: String) async -> URL? {
        let target = PhotoSelector.targetSize(width: asset.pixelWidth, height: asset.pixelHeight)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let image: UIImage? = await withCheckedContinuation { c in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                c.resume(returning: img)
            }
        }
        guard let data = image?.jpegData(compressionQuality: 0.8) else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "photo-\(hash).jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// A 540p MP4 of a video asset: small enough to caption inline and to download mid-call.
    static func exportMP4(asset: PHAsset, hash: String) async -> URL? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .mediumQualityFormat
        let box: ExportBox = await withCheckedContinuation { c in
            PHImageManager.default().requestExportSession(forVideo: asset, options: options, exportPreset: AVAssetExportPreset960x540) { session, _ in
                c.resume(returning: ExportBox(session: session))
            }
        }
        guard let session = box.session else { return nil }
        session.shouldOptimizeForNetworkUse = true
        let url = FileManager.default.temporaryDirectory.appending(path: "clip-\(hash).mp4")
        try? FileManager.default.removeItem(at: url)
        do {
            try await session.export(to: url, as: .mp4)
            return url
        } catch {
            Logger(subsystem: "app.nudge", category: "photos").error("video export failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func preview(status: PhotoStatus, running: Bool = false) {
        self.status = status
        self.isRunning = running
    }
}

extension PhotoIndexer: PHPhotoLibraryChangeObserver {
    nonisolated public func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.debounce?.cancel()
            self.debounce = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self.run(reason: "library change")
            }
        }
    }
}

/// Background URLSession so uploads continue after the app is suspended.
public final class BackgroundUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = BackgroundUploader()
    public static let identifier = "app.nudge.photo-upload"
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private let lock = NSLock()
    private var completionHandler: (() -> Void)?

    /// `contentType` must match what the URL was presigned for.
    public func upload(file: URL, to url: URL, contentType: String = "image/jpeg") {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        session.uploadTask(with: req, fromFile: file).resume()
    }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func setCompletionHandler(_ handler: @escaping () -> Void) {
        lock.withLock { completionHandler = handler }
        _ = session
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (() -> Void)? in
            let h = completionHandler
            completionHandler = nil
            return h
        }
        DispatchQueue.main.async { handler?() }
    }
}

/// Carries the export session out of the Photos callback.
private struct ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession?
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
