import Foundation
@testable import KenshikiOperationBinding
import XCTest

final class PinnedResponseBoundsTests: XCTestCase {
    func testStreamingLimitRejectsBodyWithoutContentLength() async throws {
        let url = try XCTUnwrap(URL(string: "https://regula-transport.example/stream"))
        let transport = try makeTransport()
        do {
            _ = try await transport.post(to: url, headers: [:], body: Data([1]), maxResponseBytes: 8)
            XCTFail("Streaming body exceeded the budget")
        } catch ServiceTrustError.responseTooLarge {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testContentLengthLimitRejectsBeforeReadingBody() async throws {
        let url = try XCTUnwrap(URL(string: "https://regula-transport.example/declared"))
        do {
            _ = try await makeTransport().post(to: url, headers: [:], body: Data([1]), maxResponseBytes: 8)
            XCTFail("Declared body exceeded the budget")
        } catch ServiceTrustError.responseTooLarge {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOverLimitResponseStopsUnfinishedUnderlyingTransfer() async throws {
        let url = try XCTUnwrap(URL(string: "https://regula-transport.example/declared-delayed"))
        let stopped = expectation(description: "The unfinished transfer receives stopLoading")
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("RegulaBoundedURLProtocolStopped"), object: nil, queue: nil
        ) { note in
            if note.object as? URL == url { stopped.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            _ = try await makeTransport().post(to: url, headers: [:], body: Data([1]), maxResponseBytes: 8)
            XCTFail("Declared body exceeded the budget")
        } catch ServiceTrustError.responseTooLarge {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testPolicyUsesConfiguredTimeoutAndNoCookiesOrCache() async throws {
        let url = try XCTUnwrap(URL(string: "https://regula-transport.example/policy"))
        let reply = try await makeTransport().post(
            to: url, headers: ["Authorization": "Bearer synthetic"],
            body: Data([1]), maxResponseBytes: 1024)
        let observed = try JSONDecoder().decode(ObservedPolicy.self, from: reply.body)
        XCTAssertEqual(observed.timeout, 120)
        XCTAssertFalse(observed.cookies)
        XCTAssertEqual(observed.cacheControl, "no-store")
        XCTAssertEqual(observed.cachePolicy, URLRequest.CachePolicy.reloadIgnoringLocalAndRemoteCacheData.rawValue)
        XCTAssertEqual(observed.authorization, "Bearer synthetic")
    }

    func testRedirectIsReturnedWithoutSendingBodyToDestination() async throws {
        let url = try XCTUnwrap(URL(string: "https://regula-transport.example/redirect"))
        do {
            _ = try await makeTransport().post(to: url, headers: ["Authorization": "Bearer synthetic"],
                body: Data([1]), maxResponseBytes: 1024)
            XCTFail("Redirect response was accepted")
        } catch ServiceTrustError.invalidResponse {}
    }

    private func makeTransport() throws -> PinnedServiceHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegulaBoundedURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let policy = try ServiceTrustPolicy(base64PinsByHost: ["regula-transport.example": [
            Data(repeating: 1, count: 32).base64EncodedString(), Data(repeating: 2, count: 32).base64EncodedString()]])
        return PinnedServiceHTTPTransport(policy: policy, configuration: configuration)
    }
}

private struct ObservedPolicy: Codable {
    let timeout: TimeInterval
    let cookies: Bool
    let cachePolicy: UInt
    let cacheControl: String?
    let authorization: String?
}

private final class RegulaBoundedURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "regula-transport.example" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/redirect" {
            guard let destination = URL(string: "https://regula-transport.example/destination"),
                let response = HTTPURLResponse(
                    url: url, statusCode: 307, httpVersion: nil,
                    headerFields: ["Location": destination.absoluteString])
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            var redirected = request
            redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let headers = url.path.hasPrefix("/declared") ? ["Content-Length": "999999"] : [:]
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: url.path == "/destination" ? 599 : 200,
                httpVersion: nil, headerFields: headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/declared-delayed" {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 65536))
            return
        }
        if url.path == "/policy" {
            let policy = ObservedPolicy(
                timeout: request.timeoutInterval, cookies: request.httpShouldHandleCookies,
                cachePolicy: request.cachePolicy.rawValue,
                cacheControl: request.value(forHTTPHeaderField: "Cache-Control"),
                authorization: request.value(forHTTPHeaderField: "Authorization"))
            do {
                client?.urlProtocol(self, didLoad: try JSONEncoder().encode(policy))
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        } else if url.path == "/stream" {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 9))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        NotificationCenter.default.post(name: Notification.Name("RegulaBoundedURLProtocolStopped"), object: request.url)
    }
}

// These URLProtocol fixtures test bounds, cancellation and request policy, not a TLS handshake.
private extension PinnedServiceHTTPTransport {
    func post(to url: URL, headers: [String: String], body: Data, maxResponseBytes: Int) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await send(request, maximumResponseBytes: maxResponseBytes)
        return (response.statusCode, bytes)
    }
}
