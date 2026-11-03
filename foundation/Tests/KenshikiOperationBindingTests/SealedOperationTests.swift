import Foundation
import XCTest

@testable import KenshikiOperationBinding

final class SealedOperationTests: XCTestCase {
  private func operation(
    digest: String? = nil, revision: Int64 = 0,
    issued: Int64 = 1_792_267_200, expires: Int64 = 1_792_267_500,
    audience: String = "https://synthetic.invalid"
  ) throws -> SealedOperation {
    try SealedOperation(
      applicationID: "synthetic.app", installationID: "installation-1",
      audience: audience, operationKind: "presence_share_start", operationID: "operation-1",
      targetID: "resource-1", generation: "generation-1", expectedRevision: revision,
      challengeID: "challenge-1", issuedAt: issued, expiresAt: expires,
      contentDigest: digest ?? SealedOperation.sha256(Data("{\"note\":null}".utf8)),
      purpose: "share", recipient: nil)
  }

  func testExplicitAbsenceAndKnownHash() throws {
    let prepared = try PreparedOperation(
      operation: operation(), canonicalContent: Data("{\"note\":null}".utf8))
    let bytes = try prepared.operation.canonicalBytes()
    XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\"recipient\":null"))
    XCTAssertEqual(
      prepared.clientDataHash.map { String(format: "%02x", $0) }.joined(),
      "be60a8fde6f33bd7beed7b8ef3fd4ae5bdb01fb63f75c357e3fc876d8089c66b")
    XCTAssertEqual(try prepared.operation.clientDataHash(), prepared.clientDataHash)
  }

  func testChangedAddedRemovedContentRejected() throws {
    for content in ["{\"note\":\"changed\"}", "{\"note\":null,\"photo\":{}}", "{}"] {
      XCTAssertThrowsError(
        try PreparedOperation(operation: operation(), canonicalContent: Data(content.utf8)))
    }
  }

  func testRevisionAudienceAndDomainAffectSignedBytes() throws {
    let baseline = try operation().clientDataHash()
    XCTAssertNotEqual(baseline, try operation(revision: 1).clientDataHash())
    XCTAssertNotEqual(baseline, try operation(audience: "https://other.invalid").clientDataHash())
    XCTAssertNotEqual(baseline, Data(repeating: 0, count: 32))
  }

  func testMalformedAndUnsafeInputsRejected() {
    XCTAssertThrowsError(try operation(digest: String(repeating: "A", count: 64)))
    XCTAssertThrowsError(try operation(revision: -1))
    XCTAssertThrowsError(try operation(revision: 9_007_199_254_740_991))
    XCTAssertThrowsError(try operation(expires: 1_792_267_501))
    XCTAssertThrowsError(try operation(expires: 1_792_267_200))
    XCTAssertThrowsError(try operation(audience: "https://invalid/\n"))
  }

  func testDecodedInvalidValueCannotBeSigned() throws {
    let bytes = try operation().canonicalBytes()
    let changed = String(decoding: bytes, as: UTF8.self)
      .replacingOccurrences(of: "kenshiki.sealed-operation.v1", with: "unsupported")
    let decoded = try JSONDecoder().decode(SealedOperation.self, from: Data(changed.utf8))
    XCTAssertThrowsError(try decoded.clientDataHash())
  }
  func testReceiptRequiresExactRequestDigest() throws {
    let op = try operation()
    let digest = try op.clientDataHash().map { String(format: "%02x", $0) }.joined()
    var object: [String: Any] = [
      "v": "kenshiki.operation-receipt.v1", "audience": op.audience,
      "application_id": op.applicationID, "installation_id": op.installationID,
      "operation_kind": op.operationKind, "operation_id": op.operationID,
      "target_id": op.targetID, "generation": op.generation, "content_digest": op.contentDigest,
      "request_digest": digest, "result_digest": SealedOperation.sha256(Data("{}".utf8)),
      "result_revision": 1, "expires_at": op.expiresAt,
    ]
    let receipt = try JSONDecoder().decode(
      OperationReceipt.self,
      from: JSONSerialization.data(withJSONObject: object))
    try receipt.validate(for: op, canonicalResult: Data("{}".utf8), now: op.issuedAt)
    XCTAssertThrowsError(
      try receipt.validate(
        for: op, canonicalResult: Data(#"{"changed":true}"#.utf8), now: op.issuedAt))
    for (field, value) in [("challenge_id", "another-challenge"), ("purpose", "another-purpose")] {
      var altered = try JSONSerialization.jsonObject(with: op.canonicalBytes()) as! [String: Any]
      altered[field] = value
      let other = try JSONDecoder().decode(
        SealedOperation.self,
        from: JSONSerialization.data(withJSONObject: altered))
      XCTAssertThrowsError(
        try receipt.validate(for: other, canonicalResult: Data("{}".utf8), now: op.issuedAt))
    }
    object["request_digest"] = String(repeating: "0", count: 64)
    let changed = try JSONDecoder().decode(
      OperationReceipt.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertThrowsError(
      try changed.validate(for: op, canonicalResult: Data("{}".utf8), now: op.issuedAt))
    XCTAssertThrowsError(
      try receipt.validate(
        for: operation(revision: 1), canonicalResult: Data("{}".utf8), now: op.issuedAt))
  }

}
