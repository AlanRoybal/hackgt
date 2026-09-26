import Foundation

/// Tap to add (ACC-13), the parts that decide when two phones have touched. Pure, so they're unit-tested.
///
/// Two signals, either one is enough:
/// - **Distance.** Phones with an Ultra Wideband chip range each other; tops held together read ~5–10 cm.
/// - **Bump.** Every phone has an accelerometer. A knock while the phone was held steady, landing within a
///   moment of the other phone's knock, is a tap (how the old Bump app worked). This covers phones without UWB.
public enum TapDetection {
    /// Readings at or under this many meters count as touching.
    public static let touchDistance: Float = 0.12
    /// The glow starts building from this far away.
    public static let glowDistance: Float = 0.6
    /// Consecutive close readings needed, so one noisy sample doesn't fire.
    public static let closeReadings = 2
    /// Two bumps this close together (seconds, as each phone sees them arrive) are one tap.
    public static let bumpWindow: TimeInterval = 0.5
    /// Ignore the same friend for this long after a tap, whatever happened.
    public static let cooldown: TimeInterval = 8

    /// 0 when far, 1 when touching: drives the glow at the top of the screen.
    public static func closeness(distance: Float) -> Double {
        let span = glowDistance - touchDistance
        return Double(min(max((glowDistance - distance) / span, 0), 1))
    }

    /// True when a bump arriving from the other phone at `arrival` lines up with one of ours.
    public static func bumpsMatch(local: [Date], arrival: Date) -> Bool {
        local.contains { abs($0.timeIntervalSince(arrival)) <= bumpWindow }
    }
}

/// Watches UWB distance readings for one peer.
public struct ProximityTracker: Sendable {
    private var closeCount = 0
    public private(set) var closeness: Double = 0

    public init() {}

    /// Feeds one reading (meters, nil when the peer is out of view). Returns true on the reading that makes it a tap.
    public mutating func add(distance: Float?) -> Bool {
        guard let distance else {
            closeCount = 0
            closeness = 0
            return false
        }
        closeness = TapDetection.closeness(distance: distance)
        guard distance <= TapDetection.touchDistance else { closeCount = 0; return false }
        closeCount += 1
        return closeCount == TapDetection.closeReadings
    }

    public mutating func reset() {
        closeCount = 0
        closeness = 0
    }
}

/// Finds knocks in user acceleration (gravity removed, in g). A knock is a sharp spike after the phone has
/// been held fairly steady, so walking, waving or setting the phone down don't count.
public struct BumpDetector: Sendable {
    /// Spike height, in g.
    public var threshold: Double = 0.8
    /// The average over the window before the spike must be under this.
    public var steadyBelow: Double = 0.3
    /// How much history counts as "before", in samples (about 0.15 s at 100 Hz).
    public var steadySamples = 15
    /// No second bump within this long.
    public var refractory: TimeInterval = 0.6

    private var history: [Double] = []
    private var lastBump: Date = .distantPast

    public init() {}

    /// Feeds one sample. Returns true when this sample is a bump.
    public mutating func add(magnitude: Double, at date: Date) -> Bool {
        defer {
            history.append(magnitude)
            if history.count > steadySamples { history.removeFirst(history.count - steadySamples) }
        }
        guard magnitude >= threshold, history.count == steadySamples,
              date.timeIntervalSince(lastBump) >= refractory else { return false }
        let before = history.reduce(0, +) / Double(history.count)
        guard before < steadyBelow else { return false }
        lastBump = date
        return true
    }
}

/// What the two phones say to each other over the local link. Anyone nearby with Nudge open can read it, so
/// it carries no name or photo: the id only lets a phone skip people who are already its friends, and the token
/// only works if its owner taps back. The server shares who it was once they're friends.
public struct TapHello: Codable, Sendable, Hashable {
    public var userId: String
    public var token: String
    /// Archived `NIDiscoveryToken`, when this phone can range with UWB.
    public var rangingToken: Data?

    public init(userId: String, token: String, rangingToken: Data?) {
        self.userId = userId
        self.token = token
        self.rangingToken = rangingToken
    }
}

public enum TapWire: Codable, Sendable, Hashable {
    case hello(TapHello)
    case bump

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> TapWire { try JSONDecoder().decode(TapWire.self, from: data) }
}
