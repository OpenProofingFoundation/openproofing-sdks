import CryptoKit
import Foundation
import KenshikiOperationBinding

/// Product wire codec. Canonical ordering and number serialization belong to shared foundation.
indirect enum CanonicalJSONValue: Encodable, Sendable {
    case string(String), null, object([String: CanonicalJSONValue])
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .object(let value): try container.encode(value)
        }
    }
    func canonicalJSONString() throws -> String {
        let bytes = try CanonicalJSON.canonicalize(JSONEncoder().encode(self))
        guard let text = String(data: bytes, encoding: .utf8) else { throw PulsePassportFailure.invalidRequest }
        return text
    }
}

/// Domain-separated digest preserved from Pulse's attested passport contract.
enum PulseAttestedPayloadHash {
    static func clientDataHash(domain: String, canonicalJSON: String) -> Data {
        var material = Data(domain.utf8); material.append(0); material.append(Data(canonicalJSON.utf8))
        return Data(SHA256.hash(data: material))
    }
    static func clientDataHash(domain: String, payload: CanonicalJSONValue) throws -> Data {
        clientDataHash(domain: domain, canonicalJSON: try payload.canonicalJSONString())
    }
}

public struct PulseBoundedHTTPResponse: Sendable {
    public init(statusCode:Int,body:Data,responseURL:URL?,mimeType:String?) {self.statusCode=statusCode;self.body=body;self.responseURL=responseURL;self.mimeType=mimeType}
    public let statusCode: Int
    public let body: Data
    public let responseURL: URL?
    public let mimeType: String?
}

public protocol PulseBoundedHTTPTransport: Sendable {
    func post(to url: URL, headers: [String: String], body: Data, maxResponseBytes: Int) async throws -> PulseBoundedHTTPResponse
}

public enum PulseBoundedHTTPTransportError: Error { case invalidResponse }

/// Exact Pulse transport limits, system TLS trust, redirects refused, no persistent HTTP state.
public final class URLSessionPulseBoundedHTTPTransport: PulseBoundedHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: PulsePassportRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func post(to url: URL, headers: [String: String], body: Data, maxResponseBytes: Int) async throws -> PulseBoundedHTTPResponse {
        guard url.scheme == "https", (1...1_048_576).contains(maxResponseBytes) else { throw PulseBoundedHTTPTransportError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.url == url,
              response.expectedContentLength <= maxResponseBytes else { throw PulseBoundedHTTPTransportError.invalidResponse }
        var result = Data()
        for try await byte in bytes {
            guard result.count < maxResponseBytes else { throw PulseBoundedHTTPTransportError.invalidResponse }
            result.append(byte)
        }
        return .init(statusCode: response.statusCode, body: result, responseURL: response.url, mimeType: response.mimeType)
    }
}

private final class PulsePassportRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum PulsePassportClock {
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}
