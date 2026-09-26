import Foundation
import Models
import Networking
import Observation
import Security
import os

/// Keychain-backed storage for the Cognito tokens. `AfterFirstUnlock` so background launches
/// (notification actions, VoIP pushes) can call the API while the phone is locked.
public struct KeychainStore: Sendable {
    let service: String
    let account: String

    public init(service: String = "app.nudge.session", account: String = "tokens") {
        self.service = service
        self.account = account
    }

    public func save(_ data: Data) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // -34018 (missing entitlement) means an unsigned build: the session won't survive a relaunch.
            Logger(subsystem: "app.nudge", category: "session").error("keychain save failed: \(status, privacy: .public)")
        }
    }

    public func load() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

struct StoredSession: Codable, Sendable {
    var tokens: AuthTokens
    var accessExpiresAt: Date
}

@MainActor
@Observable
public final class SessionStore: TokenProvider {
    public enum Status: Equatable, Sendable { case loading, signedOut, signedIn }

    public private(set) var status: Status = .loading
    public private(set) var me: MeResponse?
    public private(set) var userId: String?
    public var error: String?

    private var stored: StoredSession?
    private let keychain: KeychainStore
    private var api: NudgeAPI?
    private var refreshTask: Task<String?, Never>?
    private let log = Logger(subsystem: "app.nudge", category: "session")

    public init(keychain: KeychainStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        // Keychain items outlive an uninstall; UserDefaults don't. A fresh install must not resume the
        // previous install's session.
        if !defaults.bool(forKey: "session.installMarker") {
            keychain.clear()
            defaults.set(true, forKey: "session.installMarker")
        }
        if let data = keychain.load(), let s = try? NudgeJSON.decoder().decode(StoredSession.self, from: data) {
            stored = s
            userId = s.tokens.userId
        }
    }

    public func attach(api: NudgeAPI) { self.api = api }

    public var hasSession: Bool { stored != nil }
    public var idToken: String? { stored?.tokens.idToken }

    /// On launch: fetch /me if we have tokens.
    public func restore() async {
        guard stored != nil else { status = .signedOut; return }
        await loadMe()
    }

    public func loadMe() async {
        guard let api else { return }
        do {
            me = try await api.me()
            status = .signedIn
        } catch APIError.unauthorized {
            signOut()
        } catch {
            // Offline launch: keep the session, show cached UI.
            self.error = error.localizedDescription
            status = stored == nil ? .signedOut : .signedIn
        }
    }

    public func signInWithApple(identityToken: String, fullName: String?) async {
        guard let api else { return }
        do {
            adopt(try await api.signInWithApple(identityToken: identityToken, fullName: fullName))
            await loadMe()
        } catch {
            self.error = "Sign in didn't complete. \(error.localizedDescription)"
        }
    }

    public func devSignIn(username: String) async {
        guard let api else { return }
        do {
            adopt(try await api.devSignIn(username: username))
            await loadMe()
        } catch {
            self.error = "Developer sign-in failed: \(error.localizedDescription)"
        }
    }

    public func update(me: MeResponse) { self.me = me }

    public func signOut() {
        keychain.clear()
        stored = nil
        me = nil
        userId = nil
        status = .signedOut
    }

    private func adopt(_ tokens: AuthTokens, keepingRefresh old: String? = nil) {
        var t = tokens
        if t.refreshToken == nil { t.refreshToken = old }
        let s = StoredSession(tokens: t, accessExpiresAt: Date().addingTimeInterval(TimeInterval(t.expiresIn)))
        stored = s
        userId = t.userId
        if let data = try? NudgeJSON.encoder().encode(s) { keychain.save(data) }
    }

    // MARK: TokenProvider

    public func accessToken() async -> String? {
        guard let s = stored else { return nil }
        if s.accessExpiresAt.timeIntervalSinceNow < 60 { return await refreshAccessToken() }
        return s.tokens.accessToken
    }

    public func refreshAccessToken() async -> String? {
        if let refreshTask { return await refreshTask.value }
        let task = Task<String?, Never> { @MainActor in
            defer { self.refreshTask = nil }
            guard let s = self.stored, let refresh = s.tokens.refreshToken, let api = self.api else { return nil }
            do {
                let t = try await api.refresh(refreshToken: refresh, userId: s.tokens.userId)
                self.adopt(t, keepingRefresh: refresh)
                return t.accessToken
            } catch APIError.unauthorized {
                self.signOut()
                return nil
            } catch APIError.server(let status, _, _) where status == 400 || status == 401 {
                self.signOut()
                return nil
            } catch {
                self.log.error("refresh failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        refreshTask = task
        return await task.value
    }

    // MARK: Preview

    public func preview(me: MeResponse) {
        self.me = me
        self.userId = me.user.id
        self.status = .signedIn
    }
}
