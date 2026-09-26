import Foundation
import Testing
import Models
import Networking
@testable import Calls

@Suite("Photo suggestion queue")
@MainActor
struct SuggestionQueueTests {
    private func controller() -> CallController {
        let c = CallController(api: NudgeAPI(client: APIClient(baseURL: URL(string: "https://example.invalid")!)), socket: nil, selfId: { "me" }, idToken: { nil })
        c.preview(peer: PublicUser(id: "friend", handle: "friend", displayName: "Friend"), peerName: "Friend", phase: .connected, callId: "call")
        return c
    }
    private func photo(_ id: String, photoId: String? = nil, auto: Bool = false) -> PhotoSuggestion {
        PhotoSuggestion(callId: "call", suggestionId: id, photoId: photoId ?? id, thumbUrl: URL(string: "https://example.invalid/photo")!, query: id, confidence: 0.9, auto: auto)
    }

    @Test func showingFirstAdvancesInArrivalOrder() async {
        let c = controller()
        c.receive(suggestion: photo("table"))
        c.receive(suggestion: photo("keycaps"))
        #expect(c.suggestion?.id == "table")
        #expect(c.queuedSuggestions.map(\.id) == ["keycaps"])
        c.showSuggestion(photo("table"))
        #expect(c.suggestion?.id == "keycaps")
        #expect(c.queuedSuggestions.isEmpty)
        await c.remoteEnded()
    }

    @Test func dismissalAndExpiryAdvanceButStaleActionsDoNot() async {
        let c = controller()
        for id in ["a", "b", "c"] { c.receive(suggestion: photo(id)) }
        c.dismissSuggestion(photo("a"))
        #expect(c.suggestion?.id == "b")
        c.advanceSuggestion(expectedID: "a")
        c.showSuggestion(photo("a"))
        #expect(c.suggestion?.id == "b")
        c.advanceSuggestion(expectedID: "b")
        #expect(c.suggestion?.id == "c")
        await c.remoteEnded()
    }

    @Test func repeatedResultsDoNotDuplicateActiveOrQueuedPhotos() async {
        let c = controller()
        c.receive(suggestion: photo("a", photoId: "table"))
        c.receive(suggestion: photo("b", photoId: "table"))
        c.receive(suggestion: photo("c", photoId: "keys"))
        c.receive(suggestion: photo("d", photoId: "keys"))
        #expect(c.suggestion?.id == "a")
        #expect(c.queuedSuggestions.map(\.id) == ["c"])
        await c.remoteEnded()
    }

    @Test func mutingAndEndingClearPendingPhotos() async {
        let c = controller()
        c.receive(suggestion: photo("a"))
        c.receive(suggestion: photo("b"))
        c.setMuted(true)
        #expect(c.suggestion == nil && c.queuedSuggestions.isEmpty)
        c.setMuted(false)
        c.receive(suggestion: photo("c"))
        c.receive(suggestion: photo("d"))
        await c.remoteEnded()
        #expect(c.suggestion == nil && c.queuedSuggestions.isEmpty)
        c.receive(suggestion: photo("late"))
        #expect(c.suggestion == nil)
    }

    @Test func automaticResultCannotJumpAheadOfManualDecision() async {
        let c = controller()
        c.photoMode = .auto
        c.receive(suggestion: photo("manual"))
        c.receive(suggestion: photo("automatic", auto: true))
        #expect(c.suggestion?.id == "manual")
        #expect(c.queuedSuggestions.map(\.id) == ["automatic"])
        #expect(c.autoShown == nil)
        await c.remoteEnded()
    }
}
