import Foundation

/// A photo the local user asked to show.
public struct OutgoingPhoto: Hashable, Sendable, Identifiable {
    public var id: String       // photoId
    public var suggestionId: String?
    public var image: PhotoImage   // local preview (the suggestion thumbnail)

    public init(photoId: String, suggestionId: String?, image: PhotoImage) {
        self.id = photoId
        self.suggestionId = suggestionId
        self.image = image
    }
}

/// Pure state machine for the synced photo swap (SPEC REF-7/8/9, §3.10).
///
/// The driver feeds it events with the current time and executes the returned effects.
/// All timing is explicit (`now`), so tests are deterministic.
public struct PhotoShareSession: Sendable {
    public enum Phase: Hashable, Sendable {
        case offered(at: Date)
        case showing(startedAt: Date)
    }

    public struct Outgoing: Hashable, Sendable {
        public var photo: OutgoingPhoto
        public var shareId: String
        public var seq: Int
        public var durationMs: Int
        public var queueIndex: Int
        public var queueLength: Int
        public var phase: Phase
    }

    public struct Incoming: Hashable, Sendable {
        public enum Phase: Hashable, Sendable { case fetching, showing(startedAt: Date) }
        public var shareId: String
        public var senderId: String
        public var seq: Int
        public var durationMs: Int
        public var queueIndex: Int
        public var queueLength: Int
        public var image: PhotoImage?
        public var phase: Phase
    }

    public enum Event: Sendable {
        /// User tapped Show (or automatic mode fired).
        case share(OutgoingPhoto)
        case shareCreated(photoId: String, shareId: String)
        case shareFailed(photoId: String)
        /// A Chime data message arrived.
        case received(ReceivedPhotoMessage)
        /// Recipient finished downloading an offered photo.
        case incomingLoaded(shareId: String, image: PhotoImage)
        case incomingFailed(shareId: String)
        /// Timer fired (or any time check).
        case tick
        /// Sender swiped their own photo away.
        case cancelMine
        /// Drop everything (call ended).
        case reset
    }

    public enum Effect: Hashable, Sendable {
        case createShare(OutgoingPhoto)
        case send(PhotoShareMessage)
        case fetch(shareId: String, senderId: String)
        case markShown(shareId: String, shownAt: Date, durationMs: Int)
        case log(String)
    }

    public let selfId: String
    public private(set) var pending: [OutgoingPhoto] = []
    public private(set) var creating: OutgoingPhoto?
    public private(set) var outgoing: Outgoing?
    public private(set) var incoming: Incoming?
    private var nextSeq = 1
    private var burstShown = 0
    private var lastSeenTimestamp: [String: Int64] = [:]

    public init(selfId: String) { self.selfId = selfId }

    // MARK: Derived

    public func display(now: Date) -> DisplayState {
        DisplayRule.resolve(mine: mineRef, other: otherRef)
    }

    public var mineRef: PhotoRef? {
        guard let o = outgoing, case .showing(let start) = o.phase else { return nil }
        return PhotoRef(shareId: o.shareId, senderId: selfId, image: o.photo.image, startedAt: start,
                        durationMs: o.durationMs, queueIndex: o.queueIndex, queueLength: o.queueLength)
    }

    public var otherRef: PhotoRef? {
        guard let i = incoming, case .showing(let start) = i.phase, let image = i.image else { return nil }
        return PhotoRef(shareId: i.shareId, senderId: i.senderId, image: image, startedAt: start,
                        durationMs: i.durationMs, queueIndex: i.queueIndex, queueLength: i.queueLength)
    }

    /// Items not yet visible plus the one on screen — what the max-5 cap counts.
    public var outgoingCount: Int { pending.count + (creating == nil ? 0 : 1) + (outgoing == nil ? 0 : 1) }

    /// The earliest moment a `.tick` must be delivered.
    public var nextDeadline: Date? {
        var deadlines: [Date] = []
        if let o = outgoing {
            switch o.phase {
            case .offered(let at): deadlines.append(at.addingTimeInterval(PhotoTiming.readyTimeout))
            case .showing(let s): deadlines.append(s.addingTimeInterval(Double(o.durationMs) / 1000))
            }
        }
        if let i = incoming, case .showing(let s) = i.phase {
            deadlines.append(s.addingTimeInterval(Double(i.durationMs) / 1000))
        }
        return deadlines.min()
    }

    // MARK: Reducer

    public mutating func handle(_ event: Event, now: Date) -> [Effect] {
        var effects: [Effect] = []
        switch event {
        case .share(let photo):
            // Capacity counts the in-flight create and the visible photo; drop the oldest *pending* item.
            while outgoingCount >= PhotoTiming.maxQueue, !pending.isEmpty {
                let dropped = pending.removeFirst()
                effects.append(.log("queue full, dropped \(dropped.id)"))
            }
            if outgoingCount < PhotoTiming.maxQueue {
                pending.append(photo)
            }
            effects += pump()

        case .shareCreated(let photoId, let shareId):
            guard let item = creating, item.id == photoId else { break }
            creating = nil
            let pendingIncl = 1 + pending.count
            let duration = PhotoTiming.durationMs(pendingIncludingCurrent: pendingIncl)
            let seq = nextSeq
            nextSeq += 1
            let o = Outgoing(photo: item, shareId: shareId, seq: seq, durationMs: duration,
                             queueIndex: burstShown, queueLength: burstShown + pendingIncl, phase: .offered(at: now))
            outgoing = o
            effects.append(.send(PhotoShareMessage(type: .offer, seq: seq, shareId: shareId, senderId: selfId,
                                                   durationMs: duration, queueIndex: o.queueIndex, queueLength: o.queueLength)))

        case .shareFailed(let photoId):
            guard creating?.id == photoId else { break }
            creating = nil
            effects.append(.log("createShare failed for \(photoId)"))
            effects += pump()

        case .received(let received):
            effects += receive(received, now: now)

        case .incomingLoaded(let shareId, let image):
            guard var i = incoming, i.shareId == shareId, i.phase == .fetching else { break }
            i.image = image
            i.phase = .showing(startedAt: now)
            incoming = i
            effects.append(.send(PhotoShareMessage(type: .ready, seq: i.seq, shareId: shareId, senderId: selfId)))

        case .incomingFailed(let shareId):
            if incoming?.shareId == shareId { incoming = nil }
            effects.append(.log("fetch failed for \(shareId)"))

        case .tick:
            effects += expire(now: now)

        case .cancelMine:
            if let o = outgoing {
                outgoing = nil
                effects.append(.send(PhotoShareMessage(type: .cancel, seq: o.seq, shareId: o.shareId, senderId: selfId)))
                if case .showing(let start) = o.phase {
                    effects.append(.markShown(shareId: o.shareId, shownAt: start, durationMs: Int(now.timeIntervalSince(start) * 1000)))
                    burstShown += 1
                }
                effects += pump()
            }

        case .reset:
            pending = []
            creating = nil
            outgoing = nil
            incoming = nil
            burstShown = 0
        }
        if outgoing == nil, creating == nil, pending.isEmpty { burstShown = 0 }
        return effects
    }

    private mutating func pump() -> [Effect] {
        guard outgoing == nil, creating == nil, !pending.isEmpty else { return [] }
        let next = pending.removeFirst()
        creating = next
        return [.createShare(next)]
    }

    private mutating func expire(now: Date) -> [Effect] {
        var effects: [Effect] = []
        if var o = outgoing {
            switch o.phase {
            case .offered(let at) where now.timeIntervalSince(at) >= PhotoTiming.readyTimeout:
                // No `ready` within 1.5 s: show anyway.
                o.phase = .showing(startedAt: now)
                outgoing = o
            case .showing(let start) where now >= start.addingTimeInterval(Double(o.durationMs) / 1000):
                outgoing = nil
                burstShown += 1
                effects.append(.send(PhotoShareMessage(type: .end, seq: o.seq, shareId: o.shareId, senderId: selfId)))
                effects.append(.markShown(shareId: o.shareId, shownAt: start, durationMs: o.durationMs))
                effects += pump()
            default: break
            }
        }
        if let i = incoming, case .showing(let start) = i.phase,
           now >= start.addingTimeInterval(Double(i.durationMs) / 1000) {
            incoming = nil
        }
        return effects
    }

    private mutating func receive(_ r: ReceivedPhotoMessage, now: Date) -> [Effect] {
        let m = r.message
        // Chime echoes our own messages locally.
        guard m.senderId != selfId else { return [] }
        if let last = lastSeenTimestamp[m.senderId], r.timestampMs < last { return [.log("stale \(m.type) dropped")] }
        lastSeenTimestamp[m.senderId] = r.timestampMs

        switch m.type {
        case .offer:
            incoming = Incoming(shareId: m.shareId, senderId: m.senderId, seq: m.seq,
                                durationMs: m.durationMs ?? PhotoTiming.durationMs(pendingIncludingCurrent: 1),
                                queueIndex: m.queueIndex ?? 0, queueLength: m.queueLength ?? 1,
                                image: nil, phase: .fetching)
            return [.fetch(shareId: m.shareId, senderId: m.senderId)]
        case .ready:
            // The peer is ready to show *our* photo: start both clocks from now.
            if var o = outgoing, o.shareId == m.shareId, case .offered = o.phase {
                o.phase = .showing(startedAt: now)
                outgoing = o
            }
            return []
        case .end, .cancel:
            if incoming?.shareId == m.shareId { incoming = nil }
            return []
        }
    }
}
