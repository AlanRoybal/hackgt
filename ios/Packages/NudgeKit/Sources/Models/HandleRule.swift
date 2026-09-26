import Foundation

/// Handle rules (ACC-3): 3–20 chars of `a-z 0-9 _ .`, lowercase, no leading/trailing `.`, no `..`.
public enum HandleRule {
    public enum Problem: Equatable, Sendable {
        case tooShort, tooLong, badCharacters, dotPlacement, reserved

        public var message: String {
            switch self {
            case .tooShort: "At least 3 characters."
            case .tooLong: "20 characters at most."
            case .badCharacters: "Use letters, numbers, underscores and periods."
            case .dotPlacement: "Periods can't be first, last, or doubled."
            case .reserved: "That handle is reserved."
            }
        }
    }

    public static let reserved: Set<String> = [
        "admin", "administrator", "root", "support", "help", "nudge", "nudgeapp", "official", "staff",
        "system", "api", "www", "mail", "apple", "settings", "me", "you", "null", "undefined", "team",
        "security", "privacy", "terms", "about", "login", "signup", "account",
    ]

    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.")

    /// Lowercases, trims whitespace and a leading `@`.
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    public static func validate(_ raw: String) -> Problem? {
        let h = normalize(raw)
        if h.count < 3 { return .tooShort }
        if h.count > 20 { return .tooLong }
        if !h.allSatisfy({ allowed.contains($0) }) { return .badCharacters }
        if h.hasPrefix(".") || h.hasSuffix(".") || h.contains("..") { return .dotPlacement }
        if reserved.contains(h) { return .reserved }
        return nil
    }
}
