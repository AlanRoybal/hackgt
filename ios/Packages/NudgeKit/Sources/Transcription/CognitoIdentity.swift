import Foundation
import Models

/// Minimal Cognito Identity client (GetId + GetCredentialsForIdentity are unsigned JSON calls).
public actor CognitoIdentityClient {
    public struct Config: Sendable, Hashable {
        public var identityPoolId: String
        public var region: String
        public var providerName: String

        public init(identityPoolId: String, region: String, providerName: String) {
            self.identityPoolId = identityPoolId
            self.region = region
            self.providerName = providerName
        }
    }

    private let config: Config
    private let session: URLSession
    private var identityId: String?
    private var cached: AWSCredentials?

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func credentials(idToken: String) async throws -> AWSCredentials {
        if let cached, cached.isValid() { return cached }
        let logins = [config.providerName: idToken]
        if identityId == nil {
            struct GetIdResponse: Decodable { let IdentityId: String }
            let r: GetIdResponse = try await call("GetId", ["IdentityPoolId": .string(config.identityPoolId), "Logins": .object(logins.mapValues { .string($0) })])
            identityId = r.IdentityId
        }
        struct CredsResponse: Decodable {
            struct C: Decodable { let AccessKeyId: String; let SecretKey: String; let SessionToken: String; let Expiration: Double }
            let Credentials: C
        }
        let r: CredsResponse = try await call("GetCredentialsForIdentity", ["IdentityId": .string(identityId!), "Logins": .object(logins.mapValues { .string($0) })])
        let creds = AWSCredentials(accessKeyId: r.Credentials.AccessKeyId, secretAccessKey: r.Credentials.SecretKey,
                                   sessionToken: r.Credentials.SessionToken, expiration: Date(timeIntervalSince1970: r.Credentials.Expiration))
        cached = creds
        return creds
    }

    private func call<R: Decodable>(_ target: String, _ body: [String: JSONValue]) async throws -> R {
        var req = URLRequest(url: URL(string: "https://cognito-identity.\(config.region).amazonaws.com/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        req.setValue("AWSCognitoIdentityService.\(target)", forHTTPHeaderField: "X-Amz-Target")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranscriptionError.cognito(String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(R.self, from: data)
    }
}

public enum TranscriptionError: Error, Sendable {
    case cognito(String)
    case microphoneUnavailable
    case service(String)
}
