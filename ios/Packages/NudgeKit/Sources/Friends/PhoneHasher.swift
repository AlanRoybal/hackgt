import CryptoKit
import Foundation
import PhoneNumberKit

/// E.164 normalization + SHA-256 hashing (ACC-5, ACC-7). Only hashes leave the device.
public final class PhoneHasher: @unchecked Sendable {
    private let utility = PhoneNumberUtility()
    private let defaultRegion: String

    public init(defaultRegion: String = Locale.current.region?.identifier ?? "US") {
        self.defaultRegion = defaultRegion
    }

    /// Returns `+15551234567` style E.164, or nil when the input isn't a valid number.
    public func e164(_ raw: String, region: String? = nil) -> String? {
        guard let parsed = try? utility.parse(raw, withRegion: region ?? defaultRegion, ignoreType: true) else { return nil }
        return utility.format(parsed, toType: .e164)
    }

    public static func hash(e164: String) -> String {
        Data(SHA256.hash(data: Data(e164.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    /// Normalizes and hashes a batch, dropping invalid numbers and duplicates.
    public func hashes(for rawNumbers: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in rawNumbers {
            guard let e = e164(raw) else { continue }
            let h = Self.hash(e164: e)
            if seen.insert(h).inserted { out.append(h) }
        }
        return out
    }
}
