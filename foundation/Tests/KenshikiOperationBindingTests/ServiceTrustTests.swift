import Foundation
import Security
import XCTest
@testable import KenshikiOperationBinding

final class ServiceTrustTests: XCTestCase {
  private let host = "pin-test.invalid"
  private let backup = Data(repeating: 7, count: 32)
  // Synthetic self-signed SSL certificate; its private key is not a source fixture.
  private let certificateDER = Data(base64Encoded: "MIIBfzCCASWgAwIBAgIJAP48N3Xbl4m/MAoGCCqGSM49BAMCMBsxGTAXBgNVBAMMEHBpbi10ZXN0LmludmFsaWQwHhcNMjYxMDE4MDEyMjI2WhcNMjYxMTE3MDEyMjI2WjAbMRkwFwYDVQQDDBBwaW4tdGVzdC5pbnZhbGlkMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEVM/mE8gAQIZrCwVC1LfoUIPI00Y01/PmFeZStSr6fc37C3jZurjTf6q4Je++a/Fm7qEODAfELyRQk/kaoDUpHKNSMFAwGwYDVR0RBBQwEoIQcGluLXRlc3QuaW52YWxpZDATBgNVHSUEDDAKBggrBgEFBQcDATAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDAKBggqhkjOPQQDAgNIADBFAiEAtP6EUYN08jwyM8aZ7lGPndK4Iq/Vy9DuANqk13iiDXQCIGKqxrcevUaSsw/pLbr+DfSK22mwmkLFjJCFIvME09LM")!

  private func fixture() throws -> (SecCertificate, Data, ServiceTrustPolicy) {
    let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateDER as CFData))
    let pin = try XCTUnwrap(ServiceTrustPolicy.spkiSHA256(of: certificate))
    let policy = try ServiceTrustPolicy(base64PinsByHost: [host: [pin.base64EncodedString(), backup.base64EncodedString()]])
    return (certificate, pin, policy)
  }

  func testUnknownHostAndInvalidChainNeverFallBack() throws {
    let (_, pin, policy) = try fixture()
    XCTAssertTrue(policy.accepts(host: host.uppercased(), chainIsValid: true, chainSPKIHashes: [pin]))
    XCTAssertFalse(policy.accepts(host: "other.invalid", chainIsValid: true, chainSPKIHashes: [pin]))
    XCTAssertFalse(policy.accepts(host: host, chainIsValid: false, chainSPKIHashes: [pin]))
    XCTAssertFalse(policy.accepts(host: host, chainIsValid: true, chainSPKIHashes: [Data(repeating: 8, count: 32)]))
    XCTAssertFalse(policy.accepts(host: host, chainIsValid: true, chainSPKIHashes: [Data(repeating: 8, count: 32), pin]))
    XCTAssertTrue(policy.accepts(host: host, chainIsValid: true, chainSPKIHashes: [backup]))
  }

  func testConfigurationRequiresDistinctRotationKeysAndExactHosts() throws {
    let pin = backup.base64EncodedString()
    for configuration in [[:], [host: []], [host: [pin]], [host: [pin, pin]],
      [host: [pin, "bad"]], ["*.invalid": [pin, pin]], ["host.invalid.": [pin, pin]]] {
      XCTAssertThrowsError(try ServiceTrustPolicy(base64PinsByHost: configuration))
    }
    XCTAssertThrowsError(try ServiceTrustPolicy(base64PinsByHost: [
      host: [pin, Data(repeating: 8, count: 32).base64EncodedString()],
      host.uppercased(): [pin, Data(repeating: 9, count: 32).base64EncodedString()]]))
  }

  func testDestinationsRejectUnlistedOriginsCredentialsFragmentsAndPorts() throws {
    let (_, _, policy) = try fixture()
    try policy.validateDestination(URL(string: "https://pin-test.invalid/path")!)
    for url in ["http://pin-test.invalid/", "https://other.invalid/", "https://pin-test.invalid.evil.invalid/",
      "https://user:password@pin-test.invalid/", "https://pin-test.invalid/#fragment", "https://pin-test.invalid:444/"] {
      XCTAssertThrowsError(try policy.validateDestination(URL(string: url)!))
    }
  }

  func testDelegateRequiresPinnedValidSSLHost() throws {
    let (certificate, pin, policy) = try fixture()
    var value: SecTrust?
    XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &value), errSecSuccess)
    let trust = try XCTUnwrap(value)
    let fixtureDate = Date(timeIntervalSince1970: 1792286596)
    XCTAssertEqual(SecTrustSetVerifyDate(trust, fixtureDate as CFDate), errSecSuccess)
    XCTAssertEqual(SecTrustSetNetworkFetchAllowed(trust, false), errSecSuccess)
    XCTAssertEqual(SecTrustSetAnchorCertificates(trust, [certificate] as CFArray), errSecSuccess)
    XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(trust, true), errSecSuccess)
    let delegate = ServiceTrustSessionDelegate(policy: policy)
    let accepted = delegate.accepts(host: host, trust: trust)
    var trustError: CFError?
    _ = SecTrustEvaluateWithError(trust, &trustError)
    XCTAssertTrue(accepted, String(describing: trustError))
    XCTAssertFalse(delegate.accepts(host: "other.invalid", trust: trust))
    let wrong = try ServiceTrustPolicy(base64PinsByHost: [host: [backup.base64EncodedString(), Data(repeating: 8, count: 32).base64EncodedString()]])
    XCTAssertFalse(ServiceTrustSessionDelegate(policy: wrong).accepts(host: host, trust: trust))
    XCTAssertNotEqual(pin, backup)
    var unanchored: SecTrust?
    XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &unanchored), errSecSuccess)
    let untrusted = try XCTUnwrap(unanchored)
    XCTAssertEqual(SecTrustSetVerifyDate(untrusted, fixtureDate as CFDate), errSecSuccess)
    XCTAssertEqual(SecTrustSetNetworkFetchAllowed(untrusted, false), errSecSuccess)
    XCTAssertFalse(delegate.accepts(host: host, trust: untrusted))
  }

  func testMalformedDERCannotProduceAPin() {
    for bytes: [UInt8] in [[], [0x30, 0x80], [0x30, 0x84, 0xff, 0xff, 0xff, 0xff], [0x30, 0x02, 0x30, 0xff]] {
      XCTAssertNil(ServiceTrustPolicy.subjectPublicKeyInfo(Data(bytes)))
    }
  }

  func testTransportRejectsDestinationBeforeAnyNetworkUse() async throws {
    let (_, _, policy) = try fixture()
    let transport = PinnedServiceHTTPTransport(policy: policy)
    do {
      _ = try await transport.send(URLRequest(url: URL(string: "https://other.invalid/")!))
      XCTFail("Unlisted host was contacted")
    } catch ServiceTrustError.untrustedDestination {}
  }
}
