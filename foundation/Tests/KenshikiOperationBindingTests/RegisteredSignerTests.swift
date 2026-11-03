import Foundation
import XCTest

@testable import KenshikiOperationBinding

final class RegisteredSignerTests: XCTestCase {
  private actor Probe {
    var active = 0
    var maximum = 0
    var calls = 0
    func generate(_ key: String, _ digest: Data) async throws -> Data {
      active += 1
      calls += 1
      maximum = max(maximum, active)
      defer { active -= 1 }
      try await Task.sleep(nanoseconds: 2_000_000)
      if digest.first == 0 { throw OperationBindingError.invalidField("synthetic_failure") }
      return digest
    }
  }

  func testSameKeySigningIsSerialized() async throws {
    let probe = Probe()
    let signer = RegisteredAppAttestSigner { key, digest in try await probe.generate(key, digest) }
    try await withThrowingTaskGroup(of: Data.self) { group in
      for value in 1...12 {
        group.addTask {
          try await signer.assertion(
            keyID: "synthetic-key", clientDataHash: Data(repeating: UInt8(value), count: 32))
        }
      }
      for try await result in group { XCTAssertEqual(result.count, 32) }
    }
    let maximum = await probe.maximum
    let calls = await probe.calls
    XCTAssertEqual(maximum, 1)
    XCTAssertEqual(calls, 12)
  }

  func testFailureDoesNotPoisonNextRequest() async throws {
    let probe = Probe()
    let signer = RegisteredAppAttestSigner { key, digest in try await probe.generate(key, digest) }
    do {
      _ = try await signer.assertion(
        keyID: "synthetic", clientDataHash: Data(repeating: 0, count: 32))
      XCTFail("synthetic failure accepted")
    } catch {}
    let result = try await signer.assertion(
      keyID: "synthetic", clientDataHash: Data(repeating: 1, count: 32))
    XCTAssertEqual(result, Data(repeating: 1, count: 32))
  }

  func testInvalidInputNeverReachesGenerator() async throws {
    let signer = RegisteredAppAttestSigner { _, _ in
      XCTFail("invalid input reached platform")
      return Data()
    }
    do {
      _ = try await signer.assertion(keyID: "", clientDataHash: Data(repeating: 0, count: 32))
      XCTFail("empty key accepted")
    } catch {}
  }

  func testWriteProofBindsIssuedAtAndCompleteBytes() throws {
    let bytes = Data(
      #"{"body_sha256":"abc","issued_at":"2026-10-17T00:00:00.000Z","purpose":"share","source":"library"}"#
        .utf8)
    let hash = try InstallationWriteProof.clientDataHash(
      domain: "pulse:consented-photo:upload:v1",
      canonicalBinding: bytes, issuedAt: "2026-10-17T00:00:00.000Z")
    XCTAssertEqual(hash.count, 32)
    XCTAssertThrowsError(
      try InstallationWriteProof.clientDataHash(
        domain: "pulse:consented-photo:upload:v1",
        canonicalBinding: bytes, issuedAt: "different"))
    XCTAssertNotEqual(
      hash,
      try InstallationWriteProof.clientDataHash(
        domain: "different-domain",
        canonicalBinding: bytes, issuedAt: "2026-10-17T00:00:00.000Z"))
  }
}
