import CryptoKit
import Foundation
import XCTest
@testable import BiometricCapture

final class SelfieDepthTests: XCTestCase {
  func testFrontalAndTiltedPlanesHaveNoRelief() throws {
    for slope in [0.0, 0.004] {
      let result = SelfieDepthEvaluator.measure(samples: grid { x, y in 0.3 + slope * x + slope * y })
      XCTAssertEqual(result.assessment, .flat)
      XCTAssertEqual(try XCTUnwrap(result.residualRMS), 0, accuracy: 1e-12)
    }
  }

  func testFaceReliefSurvivesTiltAndTranslationOfGrid() throws {
    let samples = grid { x, y in
      0.32 + 0.002 * x - 0.025 * max(0, 1 - pow((x - 8) / 8, 2) - pow((y - 8) / 8, 2))
    }
    let original = SelfieDepthEvaluator.measure(samples: samples)
    let moved = SelfieDepthEvaluator.measure(samples: samples.map {
      .init(x: $0.x + 10_000, y: $0.y + 20_000, z: $0.z)
    })
    XCTAssertEqual(original.assessment, .live)
    XCTAssertEqual(try XCTUnwrap(original.residualRMS), try XCTUnwrap(moved.residualRMS), accuracy: 1e-10)
  }

  func testGoldenAlternatingReliefAndPolicyThreshold() throws {
    let result = SelfieDepthEvaluator.measure(samples: grid { x, y in
      0.5 + ((Int(x + y) % 2 == 0) ? 0.005 : -0.005)
    })
    XCTAssertEqual(try XCTUnwrap(result.residualRMS), 0.005, accuracy: 1e-12)
    XCTAssertEqual(result.assessment, .live)
    let strict = SelfieDepthPolicy(identifier: "test", minimumResidualRMS: 0.006,
      minimumSamples: 64, nearLimit: 0.15, farLimit: 1.2, maximumDepthAge: 0.25, samplesPerAxis: 16)
    XCTAssertEqual(SelfieDepthEvaluator.measure(samples: grid { x, y in
      0.5 + ((Int(x + y) % 2 == 0) ? 0.005 : -0.005)
    }, policy: strict).assessment, .flat)
  }

  func testInvalidCoordinatesDepthAndDegenerateGridsCannotManufactureRelief() {
    var plane = grid { _, _ in 0.4 }
    for z in [Double.nan, .infinity, 0, 0.14, 1.21] {
      plane.append(.init(x: 20, y: 20, z: z))
    }
    plane.append(.init(x: .nan, y: 3, z: 0.8))
    let result = SelfieDepthEvaluator.measure(samples: plane)
    XCTAssertEqual(result.sampleCount, 256)
    XCTAssertEqual(result.assessment, .flat)
    XCTAssertEqual(SelfieDepthEvaluator.measure(samples: Array(plane.prefix(63))).assessment, .insufficientData)
    let line = (0..<64).map { SelfieDepthSample(x: Double($0), y: 0, z: 0.4) }
    XCTAssertEqual(SelfieDepthEvaluator.measure(samples: line).assessment, .insufficientData)
    XCTAssertEqual(SelfieDepthEvaluator.measure(samples: []).assessment, .insufficientData)
  }

  func testFreshnessIncludesNativeDepthTimestampZeroFutureAndBoundary() {
    let policy = SelfieDepthPolicy.engineeringV1
    XCTAssertTrue(policy.fresh(depthTimestamp: 10, imageTimestamp: 10.25))
    for (depth, image) in [(0.0, 0.1), (10, 10.2501), (10.1, 10), (.nan, 10), (10, .infinity)] {
      XCTAssertFalse(policy.fresh(depthTimestamp: depth, imageTimestamp: image))
    }
  }

  func testCombinationFlatWinsAndBothHalvesAreRequired() {
    let states: [SelfieLivenessAssessment] = [.live, .flat, .insufficientData]
    for expression in states {
      for depth in states {
        let expected: SelfieLivenessAssessment
        if depth == .flat {
          expected = .flat
        } else if expression == .live && depth == .live {
          expected = .live
        } else {
          expected = .insufficientData
        }
        XCTAssertEqual(SelfieLivenessAssessment.combine(expression: expression, depth: depth), expected)
      }
    }
  }

  func testDepthReceiptCannotBeSubstitutedOrUpgradedFromLegacy() throws {
    var gate = SelfieAdmissionGate(policy: .init(requiredTrackedFrames: 1))
    let anchor = UUID()
    gate.start(at: 1)
    for (time, eyes) in [(1.0, Float(0)), (1.02, 0.8), (1.04, 0)] {
      gate.observe(.init(timestamp: time, anchorID: anchor, faceCount: 1, trackingObserved: true,
        leftEyeClosed: eyes, rightEyeClosed: eyes), now: time)
    }
    guard case .admit(let legacy) = gate.admit(frameTimestamp: 1.04, now: 1.04, trigger: .manual)
    else { return XCTFail("Expected expression receipt") }
    XCTAssertEqual(legacy.depthAssessment(imageSHA256: "unbound"), .insufficientData)
    let bytes = Data([1, 2, 3])
    var receipt = depthReceipt(legacy, bytes: bytes)
    let hash = receipt.depthEvidence!.imageSHA256
    XCTAssertEqual(receipt.depthAssessment(imageSHA256: hash), .live)
    let decoded = try JSONDecoder().decode(SelfieAdmissionReceipt.self, from: JSONEncoder().encode(receipt))
    XCTAssertEqual(decoded, receipt)
    XCTAssertEqual(decoded.depthAssessment(imageSHA256: hash), .live)
    XCTAssertEqual(receipt.depthAssessment(imageSHA256: "changed-image"), .insufficientData)
    receipt.depthEvidence?.ageAtAdmission = 0.3
    XCTAssertEqual(receipt.depthAssessment(imageSHA256: hash), .insufficientData)
    receipt = depthReceipt(legacy, bytes: bytes)
    receipt.frameEvidence = nil
    XCTAssertEqual(receipt.depthAssessment(imageSHA256: hash), .insufficientData)
  }

  /// RFC-0002 §4.5: Apple's temporal smoothing and hole filling can manufacture or erase relief,
  /// so a filtered map is never depth evidence, however much relief it shows.
  func testFilteredDepthIsRefused() throws {
    var gate = SelfieAdmissionGate(policy: .init(requiredTrackedFrames: 1))
    let anchor = UUID()
    gate.start(at: 1)
    for (time, eyes) in [(1.0, Float(0)), (1.02, 0.8), (1.04, 0)] {
      gate.observe(.init(timestamp: time, anchorID: anchor, faceCount: 1, trackingObserved: true,
        leftEyeClosed: eyes, rightEyeClosed: eyes), now: time)
    }
    guard case .admit(let legacy) = gate.admit(frameTimestamp: 1.04, now: 1.04, trigger: .manual)
    else { return XCTFail("Expected expression receipt") }
    let unfiltered = depthReceipt(legacy, bytes: Data([1, 2, 3]))
    let hash = try XCTUnwrap(unfiltered.depthEvidence).imageSHA256
    XCTAssertEqual(unfiltered.depthAssessment(imageSHA256: hash), .live)
    let evidence = try XCTUnwrap(unfiltered.depthEvidence)
    let filtered = SelfieDepthEvidence(
      schemaVersion: evidence.schemaVersion, measurement: evidence.measurement,
      imageTimestamp: evidence.imageTimestamp, depthTimestamp: evidence.depthTimestamp,
      orientation: evidence.orientation, mapWidth: evidence.mapWidth, mapHeight: evidence.mapHeight,
      filtered: true, ageAtAdmission: evidence.ageAtAdmission, imageSHA256: evidence.imageSHA256)
    XCTAssertEqual(filtered.assessment, .insufficientData)
    var receipt = unfiltered
    receipt.depthEvidence = filtered
    XCTAssertEqual(receipt.depthAssessment(imageSHA256: hash), .insufficientData)
  }

  private func grid(_ depth: (Double, Double) -> Double) -> [SelfieDepthSample] {
    (0..<16).flatMap { row in (0..<16).map { column in
      .init(x: Double(column), y: Double(row), z: depth(Double(column), Double(row)))
    }}
  }
}

/// Deterministic synthetic receipt used by custody tests; never a production receipt factory.
func depthReceipt(_ original: SelfieAdmissionReceipt, bytes: Data) -> SelfieAdmissionReceipt {
  var receipt = original
  receipt.frameEvidence = .init(sessionID: UUID(), sequence: 1, guideRevision: 1,
    pixelWidth: 4, pixelHeight: 4, orientation: 1, qualityRevision: 3,
    analysisDuration: 0, frameAgeAtAdmission: 0)
  receipt.depthEvidence = .init(schemaVersion: 1,
    measurement: .init(policy: .engineeringV1, sampleCount: 255, residualRMS: 0.0191),
    imageTimestamp: receipt.frameTimestamp, depthTimestamp: receipt.frameTimestamp,
    orientation: 1, mapWidth: 32, mapHeight: 32, filtered: false,
    ageAtAdmission: 0, imageSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
  return receipt
}
