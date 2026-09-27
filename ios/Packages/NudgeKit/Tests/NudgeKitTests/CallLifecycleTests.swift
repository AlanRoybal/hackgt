import Foundation
import Testing
import Models
import Networking
@testable import Calls

private actor EndCallTransport: HTTPTransport, TokenProvider {
    func accessToken() async -> String? { "test-token" }
    func refreshAccessToken() async -> String? { "test-token" }
    var requests: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request.url!.path)
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Call ending and late callbacks")
@MainActor
struct CallLifecycleTests {
    private func controller(_ transport: EndCallTransport) -> CallController {
        let api = NudgeAPI(client: APIClient(baseURL: URL(string: "https://example.invalid")!, transport: transport, tokens: transport))
        let c = CallController(api: api, socket: nil, selfId: { "me" }, idToken: { nil })
        c.preview(peer: PublicUser(id: "friend", handle: "friend", displayName: "Friend"), peerName: "Friend", phase: .connected, muted: true, callId: "test-call")
        return c
    }

    @Test func localEndNotifiesServerExactlyOnce() async {
        let transport = EndCallTransport()
        let c = controller(transport)
        var ended = 0
        c.onEnded = { _, _ in ended += 1 }
        await c.leave()
        await c.leave()
        #expect(c.phase == .ended)
        #expect(ended == 1)
        #expect(await transport.requests == ["/calls/test-call/end"])
    }

    @Test func remoteEndDoesNotSendAnotherEndRequest() async {
        let transport = EndCallTransport()
        let c = controller(transport)
        await c.remoteEnded()
        #expect(c.phase == .ended)
        #expect(await transport.requests.isEmpty)
    }

    @Test func localAudioStopEndsTheSharedCall() async throws {
        let transport = EndCallTransport()
        let c = controller(transport)
        c.audioStopped()
        for _ in 0..<50 {
            if !(await transport.requests.isEmpty) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.requests == ["/calls/test-call/end"])
        #expect(c.phase == .ended)
    }

    @Test func lateStartCallbacksCannotResurrectEndedCall() async {
        let transport = EndCallTransport()
        let c = controller(transport)
        await c.remoteEnded()
        c.audioStarted(reconnecting: true)
        c.audioConnecting(reconnecting: true)
        #expect(c.phase == .ended)
    }
}
