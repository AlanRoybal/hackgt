import Foundation
import Testing
@testable import Models
@testable import PhotoShare

@Suite("CallMediaExport — post-call save & share", .serialized)
struct CallMediaExportTests {
    private func item(_ id: String, kind: MediaType? = nil, url: String = "https://s3.test/photos/u/a.jpg?sig=1", video: String? = nil) -> CallPhoto {
        CallPhoto(shareId: id, senderId: "u_1", url: URL(string: url)!, createdAt: .now, mediaType: kind, videoUrl: video.flatMap(URL.init(string:)))
    }

    @Test func decodesPhotosFromServersWithoutVideo() throws {
        let json = #"{"shareId":"s_1","senderId":"u_1","url":"https://x/a.jpg","createdAt":"2026-09-26T15:00:00.000Z"}"#
        let p = try NudgeJSON.decoder().decode(CallPhoto.self, from: Data(json.utf8))
        #expect(p.mediaType == nil && !p.isVideo && p.exportURL.absoluteString == "https://x/a.jpg")
    }

    @Test func decodesVideosAndExportsTheClip() throws {
        let json = #"{"shareId":"s_2","senderId":"u_1","mediaType":"video","url":"https://x/a.jpg","videoUrl":"https://x/a.mp4","createdAt":"2026-09-26T15:00:00Z"}"#
        let v = try NudgeJSON.decoder().decode(CallPhoto.self, from: Data(json.utf8))
        #expect(v.isVideo && v.exportURL.absoluteString == "https://x/a.mp4")
    }

    @Test func videosWithoutAClipExportTheImage() {
        let clipless = item("s_4", kind: .video)
        #expect(!clipless.isVideo && clipless.exportURL == clipless.url)
    }

    @Test func namesFilesByShareAndExtension() {
        #expect(CallMediaExport.fileName(for: item("s_1")) == "nudge-s_1.jpg")
        #expect(CallMediaExport.fileName(for: item("s_2", kind: .video, video: "https://s3.test/photos/u/a.MOV?sig=1")) == "nudge-s_2.mov")
        #expect(CallMediaExport.fileName(for: item("s_3", url: "https://s3.test/blob")) == "nudge-s_3.jpg")
        #expect(CallMediaExport.fileName(for: item("s_4", kind: .video, video: "https://s3.test/clip")) == "nudge-s_4.mp4")
    }

    @Test func refreshesExpiredLinksOnce() async throws {
        StubProtocol.responses = [
            "https://s3.test/ok.jpg": (200, Data("photo".utf8)),
            "https://s3.test/expired.mp4": (403, Data()),
            "https://s3.test/fresh.mp4": (200, Data("clip".utf8)),
        ]
        let session = StubProtocol.session()
        let items = [item("s_1", url: "https://s3.test/ok.jpg"), item("s_2", kind: .video, url: "https://s3.test/p.jpg", video: "https://s3.test/expired.mp4")]
        let fresh = [items[0], item("s_2", kind: .video, url: "https://s3.test/p.jpg", video: "https://s3.test/fresh.mp4")]
        let refreshes = Counter()
        let files = try await CallMediaExport.download(items, refresh: { await refreshes.bump(); return fresh }, session: session)
        defer { CallMediaExport.discard(files) }

        #expect(await refreshes.value == 1)
        #expect(files.map(\.kind) == [.photo, .video])
        #expect(try Data(contentsOf: files[1].url) == Data("clip".utf8))
        CallMediaExport.discard(files)
        #expect(!FileManager.default.fileExists(atPath: files[0].url.deletingLastPathComponent().path))
    }

    @Test func failsWhenRefreshDoesNotHelp() async {
        StubProtocol.responses = ["https://s3.test/gone.jpg": (403, Data())]
        await #expect(throws: CallMediaExport.Failure.downloadFailed) {
            _ = try await CallMediaExport.download([item("s_1", url: "https://s3.test/gone.jpg")], refresh: { nil }, session: StubProtocol.session())
        }
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (status, body) = Self.responses[url.absoluteString] ?? (404, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
