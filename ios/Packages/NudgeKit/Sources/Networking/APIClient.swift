import Foundation
import Models

public enum APIError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case server(status: Int, code: String, message: String)
    case transport(String)
    case decoding(String)

    public var code: String? {
        if case .server(_, let code, _) = self { return code }
        return nil
    }

    public var status: Int? {
        switch self {
        case .unauthorized: 401
        case .server(let s, _, _): s
        default: nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Your session expired. Please sign in again."
        case .server(_, _, let message): message
        case .transport: "Can't reach Nudge. Check your connection."
        case .decoding: "Something went wrong reading the response."
        }
    }
}

/// Everything that talks HTTP goes through a transport so tests and screenshot mode can swap it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("No HTTP response") }
        return (data, http)
    }
}

/// Supplies and refreshes the bearer token. Implemented by `Auth.SessionStore`.
public protocol TokenProvider: AnyObject, Sendable {
    func accessToken() async -> String?
    /// Refresh after a 401. Returns the new token, or nil when the session is gone.
    func refreshAccessToken() async -> String?
}

public actor APIClient {
    public let baseURL: URL
    let transport: HTTPTransport
    weak var tokens: (any TokenProvider)?
    private let decoder = NudgeJSON.decoder()
    private let encoder = NudgeJSON.encoder()

    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport(), tokens: (any TokenProvider)? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
    }

    public func setTokenProvider(_ provider: any TokenProvider) {
        tokens = provider
    }

    public enum Method: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

    struct Empty: Codable {}

    public func request<Response: Decodable & Sendable>(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], authenticated: Bool = true,
        as: Response.Type = Response.self
    ) async throws -> Response {
        try await perform(method, path, query: query, bodyData: nil, authenticated: authenticated)
    }

    public func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: Method, _ path: String, body: Body, authenticated: Bool = true, as: Response.Type = Response.self
    ) async throws -> Response {
        let data = try encoder.encode(body)
        return try await perform(method, path, query: [], bodyData: data, authenticated: authenticated)
    }

    /// For endpoints that return 202/204 or a body we ignore.
    public func send(_ method: Method, _ path: String) async throws {
        let _: IgnoredBody = try await perform(method, path, query: [], bodyData: nil, authenticated: true)
    }

    public func send<Body: Encodable & Sendable>(_ method: Method, _ path: String, body: Body) async throws {
        let data = try encoder.encode(body)
        let _: IgnoredBody = try await perform(method, path, query: [], bodyData: data, authenticated: true)
    }

    private func perform<Response: Decodable>(
        _ method: Method, _ path: String, query: [URLQueryItem], bodyData: Data?, authenticated: Bool
    ) async throws -> Response {
        var token: String? = nil
        if authenticated {
            token = await tokens?.accessToken()
            guard token != nil else { throw APIError.unauthorized }
        }
        var (data, http) = try await attempt(method, path, query: query, body: bodyData, token: token)
        if http.statusCode == 401, authenticated {
            guard let fresh = await tokens?.refreshAccessToken() else { throw APIError.unauthorized }
            (data, http) = try await attempt(method, path, query: query, body: bodyData, token: fresh)
            if http.statusCode == 401 { throw APIError.unauthorized }
        }
        guard (200..<300).contains(http.statusCode) else {
            if let body = try? decoder.decode(APIErrorBody.self, from: data) {
                throw APIError.server(status: http.statusCode, code: body.error.code, message: body.error.message)
            }
            throw APIError.server(status: http.statusCode, code: "http_\(http.statusCode)", message: "Request failed (\(http.statusCode)).")
        }
        if Response.self == IgnoredBody.self { return IgnoredBody() as! Response }
        do {
            return try decoder.decode(Response.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw APIError.decoding("\(method.rawValue) \(path): \(error)")
        }
    }

    private func attempt(_ method: Method, _ path: String, query: [URLQueryItem], body: Data?, token: String?) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method.rawValue
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        // One retry on transport errors for idempotent methods.
        var lastError: Error?
        for attemptIndex in 0..<2 {
            do {
                return try await transport.send(req)
            } catch {
                lastError = error
                if method == .post || method == .patch || attemptIndex == 1 { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        throw APIError.transport(lastError.map { "\($0)" } ?? "unknown")
    }
}

public struct IgnoredBody: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
}
