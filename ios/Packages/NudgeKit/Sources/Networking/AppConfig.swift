import Foundation

/// Build-time configuration read from Info.plist (populated from `ios/Config/Env.xcconfig`).
public struct AppConfig: Sendable {
    public var apiBaseURL: URL
    public var webSocketURL: URL
    public var appGroup: String
    public var isDebug: Bool

    public init(apiBaseURL: URL, webSocketURL: URL, appGroup: String, isDebug: Bool) {
        self.apiBaseURL = apiBaseURL
        self.webSocketURL = webSocketURL
        self.appGroup = appGroup
        self.isDebug = isDebug
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> AppConfig {
        func string(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let api = URL(string: string("NudgeAPIBaseURL")).flatMap { $0.host() == nil ? nil : $0 }
            ?? URL(string: "https://api.invalid")!
        let ws = URL(string: string("NudgeWebSocketURL")).flatMap { $0.host() == nil ? nil : $0 }
            ?? URL(string: "wss://ws.invalid")!
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return AppConfig(apiBaseURL: api, webSocketURL: ws, appGroup: string("NudgeAppGroup"), isDebug: debug)
    }

    public var isConfigured: Bool { !apiBaseURL.absoluteString.contains(".invalid") }
}
