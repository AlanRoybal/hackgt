import CryptoKit
import Foundation

public struct AWSCredentials: Sendable, Hashable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date?

    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }

    public func isValid(at now: Date = Date()) -> Bool {
        guard let expiration else { return true }
        return expiration.timeIntervalSince(now) > 120
    }
}

/// AWS Signature Version 4 query-string presigning (the only SigV4 flavour the app needs).
public enum SigV4 {
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = sha256Hex(Data())

    public static func presign(
        url: URL, method: String = "GET", credentials: AWSCredentials, region: String, service: String,
        date: Date, expires: Int, payloadHash: String = emptyPayloadHash
    ) -> URL {
        let amzDate = timestamp(date)
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let host = comps.port.map { "\(comps.host!):\($0)" } ?? comps.host!

        var params: [(String, String)] = (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        params.append(("X-Amz-Algorithm", "AWS4-HMAC-SHA256"))
        params.append(("X-Amz-Credential", "\(credentials.accessKeyId)/\(scope)"))
        params.append(("X-Amz-Date", amzDate))
        params.append(("X-Amz-Expires", String(expires)))
        if let token = credentials.sessionToken { params.append(("X-Amz-Security-Token", token)) }
        params.append(("X-Amz-SignedHeaders", "host"))

        let canonicalQuery = canonicalQueryString(params)
        let path = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        let canonicalRequest = [method, path, canonicalQuery, "host:\(host)\n", "host", payloadHash].joined(separator: "\n")
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let key = signingKey(secret: credentials.secretAccessKey, day: day, region: region, service: service)
        let signature = hmac(key: key, Data(stringToSign.utf8)).hexString

        comps.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=\(signature)"
        return comps.url!
    }

    public static func signingKey(secret: String, day: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), Data(day.utf8))
        let kRegion = hmac(key: kDate, Data(region.utf8))
        let kService = hmac(key: kRegion, Data(service.utf8))
        return hmac(key: kService, Data("aws4_request".utf8))
    }

    public static func canonicalQueryString(_ params: [(String, String)]) -> String {
        let encoded: [(key: String, value: String)] = params.map { (key: uriEncode($0.0), value: uriEncode($0.1)) }
        let sorted = encoded.sorted { a, b in a.key == b.key ? a.value < b.value : a.key < b.key }
        return sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    public static func uriEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    public static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func hmac(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }
}

extension Data {
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
