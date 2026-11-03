import Foundation
import Security

/// Owns its ephemeral session so callers cannot inject a delegate, cache or redirect bypass.
/// Apple contract: URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:).
public final class PinnedServiceHTTPTransport: @unchecked Sendable {
  private let policy: ServiceTrustPolicy
  private let session: URLSession

  public convenience init(policy: ServiceTrustPolicy) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    self.init(policy: policy, configuration: configuration)
  }

  // Package-internal deterministic URLProtocol fixtures exercise body/cancellation behavior.
  // Public adopters cannot replace the owned session configuration or its trust delegate.
  init(policy: ServiceTrustPolicy, configuration: URLSessionConfiguration) {
    self.policy = policy
    session = URLSession(configuration: configuration, delegate: ServiceTrustSessionDelegate(policy: policy), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  public func send(_ request: URLRequest, maximumResponseBytes: Int = 1_048_576) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url else { throw ServiceTrustError.untrustedDestination }
    try policy.validateRequest(request)
    guard (1...8_388_608).contains(maximumResponseBytes) else { throw ServiceTrustError.invalidConfiguration }
    var outgoing = request
    outgoing.httpShouldHandleCookies = false
    outgoing.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    outgoing.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    let (bytes, response) = try await session.bytes(for: outgoing)
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse, http.url == url,
      !(300..<400).contains(http.statusCode)
    else { throw ServiceTrustError.invalidResponse }
    if response.expectedContentLength > Int64(maximumResponseBytes) { throw ServiceTrustError.responseTooLarge }
    var body = Data()
    for try await byte in bytes {
      guard body.count < maximumResponseBytes else { throw ServiceTrustError.responseTooLarge }
      body.append(byte)
    }
    return (body, http)
  }
}

final class ServiceTrustSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let policy: ServiceTrustPolicy
  init(policy: ServiceTrustPolicy) { self.policy = policy }

  func urlSession(
    _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func urlSession(
    _: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else { completionHandler(.cancelAuthenticationChallenge, nil); return }
    let host = challenge.protectionSpace.host
    let accepted = accepts(host: host, trust: trust)
    completionHandler(accepted ? .useCredential : .cancelAuthenticationChallenge,
      accepted ? URLCredential(trust: trust) : nil)
  }

  func accepts(host: String, trust: SecTrust) -> Bool {
    guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess else { return false }
    let valid = SecTrustEvaluateWithError(trust, nil)
    let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    guard let leaf = chain.first, let digest = ServiceTrustPolicy.spkiSHA256(of: leaf) else { return false }
    return policy.accepts(host: host, chainIsValid: valid, chainSPKIHashes: [digest])
  }
}
