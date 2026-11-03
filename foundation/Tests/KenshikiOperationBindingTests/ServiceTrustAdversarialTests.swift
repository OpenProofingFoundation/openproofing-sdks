import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class ServiceTrustAdversarialTests: XCTestCase {
  private let host = "service-test.invalid"
  private let current = Data(repeating: 0x31, count: 32)
  private let rotation = Data(repeating: 0x72, count: 32)

  private func policy() throws -> ServiceTrustPolicy {
    try ServiceTrustPolicy(base64PinsByHost: [host: [current.base64EncodedString(), rotation.base64EncodedString()]])
  }

  func testAnIssuerPinCannotAuthenticateADifferentLeaf() throws {
    let policy = try policy()
    let differentLeaf = Data(repeating: 0x99, count: 32)
    XCTAssertFalse(policy.accepts(host: host, chainIsValid: true, chainSPKIHashes: [differentLeaf, current, rotation]))
    XCTAssertFalse(policy.accepts(host: host, chainIsValid: true, chainSPKIHashes: []))
    XCTAssertFalse(policy.accepts(host: host, chainIsValid: false, chainSPKIHashes: [current]))
    XCTAssertTrue(policy.accepts(host: host, chainIsValid: true, chainSPKIHashes: [rotation, differentLeaf]))
    XCTAssertFalse(policy.accepts(host: "unconfigured.invalid", chainIsValid: true, chainSPKIHashes: [current]))
  }

  func testHTTPAuthorityCannotOverrideTheApprovedTLSDestination() throws {
    let policy = try policy()
    for name in ["Host", "host", "HOST", ":authority"] {
      for value in [host, "other.invalid", "service-test.invalid:443"] {
        var request = URLRequest(url: URL(string: "https://service-test.invalid/action")!)
        request.allHTTPHeaderFields = [name: value]
        XCTAssertThrowsError(try policy.validateRequest(request)) { error in
          XCTAssertEqual(error as? ServiceTrustError, .untrustedDestination)
        }
      }
    }
    try policy.validateRequest(URLRequest(url: URL(string: "https://service-test.invalid/action?key=value")!))
  }

  func testOriginConfusionAndMalformedProvisioningFailClosed() throws {
    let policy = try policy()
    for text in ["http://service-test.invalid/", "https://service-test.invalid.other.invalid/",
      "https://service-test.invalid./", "https://service-test.invalid:8443/",
      "https://service-test.invalid@other.invalid/", "https://user@service-test.invalid/",
      "https://service-test.invalid/#fragment"] {
      XCTAssertThrowsError(try policy.validateDestination(URL(string: text)!))
    }
    let valid = [current.base64EncodedString(), rotation.base64EncodedString()]
    for entries in [[host: [valid[0], valid[0]]], [host: [valid[0], valid[1] + "\n"]],
      [host: [valid[0], Data(repeating: 1, count: 31).base64EncodedString()]],
      ["service-test.invalid.": valid], ["service_test.invalid": valid],
      ["service-test.invalid": valid, "SERVICE-TEST.INVALID": valid]] {
      XCTAssertThrowsError(try ServiceTrustPolicy(base64PinsByHost: entries))
    }
  }

  func testDERBoundaryAndLengthErrorsCannotProduceAKeyHashInput() {
    let invalid: [[UInt8]] = [[], [0x30], [0x30, 0x80], [0x30, 0x81, 0x00],
      [0x30, 0x82, 0x00, 0x80], [0x30, 0x84, 0xff, 0xff, 0xff, 0xff],
      [0x30, 0x02, 0x30, 0x00, 0x00], [0x30, 0x02, 0x04, 0x00],
      [0x30, 0x03, 0x30, 0x02, 0x00]]
    for bytes in invalid { XCTAssertNil(ServiceTrustPolicy.subjectPublicKeyInfo(Data(bytes))) }
  }

  func testRedirectDelegateRefusesEvenAnotherConfiguredDestinationWithoutSendingATask() throws {
    let policy = try policy()
    let delegate = ServiceTrustSessionDelegate(policy: policy)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let source = URL(string: "https://service-test.invalid/original")!
    let task = session.dataTask(with: source)
    defer { task.cancel() }
    for destination in ["https://service-test.invalid/changed", "https://other.invalid/"] {
      let callback = expectation(description: "redirect declined")
      delegate.urlSession(session, task: task,
        willPerformHTTPRedirection: HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!,
        newRequest: URLRequest(url: URL(string: destination)!)) { next in
          XCTAssertNil(next)
          callback.fulfill()
        }
      wait(for: [callback], timeout: 1)
    }
  }

  func testTransportRejectsInvalidRequestsAndBoundsBeforeNetworkAccess() async throws {
    let transport = PinnedServiceHTTPTransport(policy: try policy())
    var overridden = URLRequest(url: URL(string: "https://service-test.invalid/")!)
    overridden.setValue("other.invalid", forHTTPHeaderField: "Host")
    do {
      _ = try await transport.send(overridden)
      XCTFail("An authority override reached transport")
    } catch { XCTAssertEqual(error as? ServiceTrustError, .untrustedDestination) }
    for bound in [0, -1, 8_388_609] {
      do {
        _ = try await transport.send(URLRequest(url: URL(string: "https://service-test.invalid/")!), maximumResponseBytes: bound)
        XCTFail("Invalid response bound reached transport")
      } catch { XCTAssertEqual(error as? ServiceTrustError, .invalidConfiguration) }
    }
  }
}
