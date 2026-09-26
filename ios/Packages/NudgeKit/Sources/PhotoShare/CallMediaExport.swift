import Foundation
import Models
import Photos
import os

/// Post-call export: downloads the photos and videos shown on a call, then saves them to the library
/// or hands the files to the share sheet. The recap's links expire after 5 minutes, so a failed
/// download asks `refresh` for new ones once before giving up.
public enum CallMediaExport {
    public enum Failure: Error, Equatable, Sendable {
        case photosAccessDenied
        case downloadFailed
    }

    /// A downloaded item, living in its own temporary folder until `discard` is called.
    public struct File: Sendable, Hashable {
        public var url: URL
        public var kind: CallPhoto.Kind
    }

    private static let log = Logger(subsystem: "app.nudge", category: "export")

    /// `nudge-<shareId>.<ext>`, taking the extension from the link (S3 keeps the key's) and falling back by kind.
    public static func fileName(for item: CallPhoto) -> String {
        let ext = item.exportURL.pathExtension.lowercased()
        let fallback = item.isVideo ? "mp4" : "jpg"
        return "nudge-\(item.shareId).\(ext.isEmpty ? fallback : ext)"
    }

    /// Downloads every item, oldest first. Throws `.downloadFailed` if any item still fails after one refresh.
    public static func download(
        _ items: [CallPhoto],
        refresh: @Sendable () async -> [CallPhoto]?,
        session: URLSession = .shared
    ) async throws -> [File] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "call-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [File] = []
        var fresh: [String: CallPhoto]?
        do {
            for item in items {
                let dest = dir.appending(path: fileName(for: item))
                if await fetch(item.exportURL, to: dest, session: session) {
                    files.append(File(url: dest, kind: item.isVideo ? .video : .photo))
                    continue
                }
                if fresh == nil { fresh = Dictionary((await refresh() ?? []).map { ($0.shareId, $0) }, uniquingKeysWith: { a, _ in a }) }
                guard let renewed = fresh?[item.shareId], await fetch(renewed.exportURL, to: dest, session: session) else {
                    throw Failure.downloadFailed
                }
                files.append(File(url: dest, kind: renewed.isVideo ? .video : .photo))
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return files
    }

    /// Adds the files to the photo library as new assets. Needs add-only access, which is asked for here.
    public static func saveToPhotos(_ files: [File]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.photosAccessDenied }
        try await PHPhotoLibrary.shared().performChanges {
            for file in files {
                PHAssetCreationRequest.forAsset().addResource(with: file.kind == .video ? .video : .photo, fileURL: file.url, options: nil)
            }
        }
    }

    /// Deletes the temporary folder the files were downloaded into.
    public static func discard(_ files: [File]) {
        for dir in Set(files.map { $0.url.deletingLastPathComponent() }) { try? FileManager.default.removeItem(at: dir) }
    }

    private static func fetch(_ url: URL, to dest: URL, session: URLSession) async -> Bool {
        do {
            let (tmp, response) = try await session.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch {
            log.error("download failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
