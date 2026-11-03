import Foundation
import XCTest
@testable import PassportSDK

final class PassportAuthenticatedPortraitTests: XCTestCase {
  private let original = Data("abc".utf8)
  private let portrait = Data([0xff, 0xd8, 0xff, 0xd9])
  private let sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  func testMatchingSODPreservesOriginalBytesAndNormalizesOnlyDigestSpelling() throws {
    let admitted = try XCTUnwrap(PassportAuthenticatedPortrait.admit(
      dg2: original, portrait: portrait, sodDigest: sha256.uppercased(), reportedMatch: true))
    XCTAssertEqual(admitted.dg2, original)
    XCTAssertEqual(admitted.portrait, portrait)
    XCTAssertEqual(admitted.digest, sha256)
    XCTAssertEqual(admitted.algorithm, "SHA-256")
  }

  func testChangedDG2CannotBeRetainedEvenWhenUpstreamReportsAMatch() {
    for index in original.indices {
      var changed = original
      changed[index] ^= 1
      XCTAssertNil(PassportAuthenticatedPortrait.admit(
        dg2: changed, portrait: portrait, sodDigest: sha256, reportedMatch: true))
    }
  }

  func testMissingOrUnmatchedSODCannotRetainAnyPortraitTuple() {
    XCTAssertNil(PassportAuthenticatedPortrait.admit(
      dg2: original, portrait: portrait, sodDigest: sha256, reportedMatch: false))
    for digest in [nil, "", String(repeating: "g", count: 64), String(repeating: "0", count: 64), String(sha256.dropLast())] {
      XCTAssertNil(PassportAuthenticatedPortrait.admit(
        dg2: original, portrait: portrait, sodDigest: digest, reportedMatch: true))
    }
  }

  func testDigestCannotSurviveWithoutBothOriginalAndPortrait() {
    for missing in [nil, Data()] {
      XCTAssertNil(PassportAuthenticatedPortrait.admit(
        dg2: missing, portrait: portrait, sodDigest: sha256, reportedMatch: true))
      XCTAssertNil(PassportAuthenticatedPortrait.admit(
        dg2: original, portrait: missing, sodDigest: sha256, reportedMatch: true))
    }
  }

  func testSupportedSODAlgorithmsMatchIndependentABCFixtures() throws {
    let vectors = [
      ("SHA-1", "a9993e364706816aba3e25717850c26c9cd0d89d"),
      ("SHA-256", sha256),
      ("SHA-384", "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"),
      ("SHA-512", "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"),
    ]
    for (name, digest) in vectors {
      let admitted = try XCTUnwrap(PassportAuthenticatedPortrait.admit(
        dg2: original, portrait: portrait, sodDigest: digest, reportedMatch: true))
      XCTAssertEqual(admitted.algorithm, name)
      XCTAssertEqual(admitted.digest, digest)
    }
  }
}
