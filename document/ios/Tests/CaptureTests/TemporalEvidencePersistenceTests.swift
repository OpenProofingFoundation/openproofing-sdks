#if os(iOS)
  import CryptoKit
  import Foundation
  import CaptureEvidenceCustody
  import XCTest

  @testable import DocumentCapture
  import DocumentCaptureJournal
  @testable import DocumentCaptureApple

  @MainActor
  final class TemporalEvidencePersistenceTests: XCTestCase {
    func testRetainsGraphAcrossStoreReopenAndKeepsUnpublishedFramesOutOfLibrary() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      var manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let evidence = evidence(for: manifest)
      manifest.temporalEvidence = try await CaptureTemporalEvidencePersistence.retain(
        evidence, manifest: manifest, store: fixture.store)
      let unpublished = try await fixture.store.originalRecordIDs()
      XCTAssertTrue(unpublished.isEmpty)
      try await fixture.retain(manifest)
      let reopened = try fixture.reopen()
      let ids = try await CaptureTemporalEvidencePersistence.verify(manifest, store: reopened)
      XCTAssertEqual(ids.count, 2)
      let sessions = try await reopened.originalRecordIDs()
      XCTAssertEqual(sessions, [manifest.captureID])
      XCTAssertEqual(manifest.temporalEvidence?.status, "partial")
    }

    func testMissingFrameFailsVerification() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      var manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      manifest.temporalEvidence = try await CaptureTemporalEvidencePersistence.retain(
        evidence(for: manifest), manifest: manifest, store: fixture.store)
      try await fixture.retain(manifest)
      let ids = try await fixture.store.matchingRecordIDs(recordKind: "temporalFrame")
      let frameID = try XCTUnwrap(ids.first)
      try FileManager.default.removeItem(
        at: fixture.directory.appendingPathComponent(frameID.uuidString + ".evidence"))
      do {
        try await CaptureTemporalEvidencePersistence.verify(manifest, store: fixture.store)
        XCTFail("Missing linked pixels were accepted")
      } catch {}
    }

    func testCrossCaptureBindingAndCorruptPayloadRejectedBeforePublication() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let other = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      for invalid in [evidence(for: other), evidence(for: manifest, corruptPayload: true)] {
        do {
          _ = try await CaptureTemporalEvidencePersistence.retain(
            invalid, manifest: manifest, store: fixture.store)
          XCTFail("Invalid evidence accepted")
        } catch {}
      }
      let ids = try await fixture.store.list()
      XCTAssertTrue(ids.isEmpty)
    }

    func testLegacyManifestWithoutTemporalFieldRemainsReadable() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let data = try JSONEncoder().encode(manifest)
      let decoded = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: data)
      XCTAssertNil(decoded.temporalEvidence)
      let ids = try await CaptureTemporalEvidencePersistence.verify(decoded, store: fixture.store)
      XCTAssertTrue(ids.isEmpty)
    }

    func testManifestContractMutationsRejected() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let original = evidence(for: manifest)
      let mutations: [(inout [String: Any]) throws -> Void] = [
        { $0["schemaVersion"] = 2 },
        { $0["status"] = "authentic" },
        { value in
          var binding = try XCTUnwrap(value["binding"] as? [String: Any])
          binding["sessionID"] = UUID().uuidString
          value["binding"] = binding
        },
        { value in
          var binding = try XCTUnwrap(value["binding"] as? [String: Any])
          binding["stillSHA256"] = String(repeating: "0", count: 64)
          value["binding"] = binding
        },
        { value in
          var config = try XCTUnwrap(value["configuration"] as? [String: Any])
          config["maximumBytes"] = 3
          value["configuration"] = config
        },
        { value in
          var config = try XCTUnwrap(value["configuration"] as? [String: Any])
          config["preCaptureDuration"] = -1
          value["configuration"] = config
        },
        { value in
          var frames = try XCTUnwrap(value["frames"] as? [[String: Any]])
          frames[0]["sequenceNumber"] = 9
          value["frames"] = frames
        },
      ]
      for mutation in mutations {
        var object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: JSONEncoder().encode(original.manifest))
            as? [String: Any])
        try mutation(&object)
        let modified = try JSONDecoder().decode(
          DocumentTemporalManifest.self, from: JSONSerialization.data(withJSONObject: object))
        do {
          _ = try await CaptureTemporalEvidencePersistence.retain(
            .init(manifest: modified, frames: original.frames), manifest: manifest,
            store: fixture.store)
          XCTFail("Invalid manifest accepted")
        } catch {}
      }
      let ids = try await fixture.store.list()
      XCTAssertTrue(ids.isEmpty)
    }

    func testRecordedClaimRequiresActualOrderedCoverage() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      var manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let recorded = try recordedEvidence(for: manifest)
      manifest.temporalEvidence = try await CaptureTemporalEvidencePersistence.retain(
        recorded, manifest: manifest, store: fixture.store)
      try await CaptureTemporalEvidencePersistence.verify(manifest, store: fixture.store)
      for mutation in coverageMutations {
        let invalid = try modified(recorded, mutation)
        do {
          _ = try await CaptureTemporalEvidencePersistence.retain(
            invalid, manifest: manifest, store: fixture.store)
          XCTFail("Self-consistent but false coverage claim was accepted")
        } catch {}
      }
    }

    func testPartialStillEnforcesDiagnosticBounds() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let original = evidence(for: manifest)
      for count in [-1, 0] {
        let invalid = try modified(original) { value in
          value["gaps"] = [["reason": "fixture", "count": count]]
        }
        do {
          _ = try await CaptureTemporalEvidencePersistence.retain(
            invalid, manifest: manifest, store: fixture.store)
          XCTFail("Invalid diagnostic occurrence count accepted")
        } catch {}
      }
      let invalid = try modified(original) { value in
        value["issues"] = Array(repeating: "fixture", count: 129)
      }
      do {
        _ = try await CaptureTemporalEvidencePersistence.retain(
          invalid, manifest: manifest, store: fixture.store)
        XCTFail("Diagnostic cap exceeded")
      } catch {}
    }
  }

  extension TemporalEvidencePersistenceTests {
    private var coverageMutations: [(inout [String: Any]) throws -> Void] {
      [
        { value in
          var binding = try XCTUnwrap(value["binding"] as? [String: Any])
          binding.removeValue(forKey: "stillHostTimeSeconds")
          value["binding"] = binding
        },
        { value in
          var frames = try XCTUnwrap(value["frames"] as? [[String: Any]])
          frames[0].removeValue(forKey: "hostTimeSeconds")
          value["frames"] = frames
        },
        { value in
          var frames = try XCTUnwrap(value["frames"] as? [[String: Any]])
          frames[1]["hostTimeSeconds"] = 1.1
          value["frames"] = frames
        },
        { value in
          var frames = try XCTUnwrap(value["frames"] as? [[String: Any]])
          frames[1]["timestamp"] = frames[0]["timestamp"]
          value["frames"] = frames
        },
        { value in
          var correlation = try XCTUnwrap(value["clockCorrelation"] as? [String: Any])
          correlation["hostBeforeSeconds"] = 1
          value["clockCorrelation"] = correlation
        },
        { value in
          var samples = try XCTUnwrap(value["motionSamples"] as? [[String: Any]])
          samples[1]["bootTimeSeconds"] = 1.1
          value["motionSamples"] = samples
        },
        { value in
          var samples = try XCTUnwrap(value["motionSamples"] as? [[String: Any]])
          samples[1]["bootTimeSeconds"] = 0
          value["motionSamples"] = samples
        },
      ]
    }

    private func recordedEvidence(for manifest: CaptureRecords.Manifest) throws
      -> DocumentTemporalEvidence
    {
      try modified(evidence(for: manifest)) { value in
        value["status"] = "recorded"
        value["termination"] = "completed"
        value["issues"] = []
        var binding = try XCTUnwrap(value["binding"] as? [String: Any])
        binding["stillHostTimeSeconds"] = 1
        value["binding"] = binding
        var frames = try XCTUnwrap(value["frames"] as? [[String: Any]])
        frames.append(frames[0])
        for index in 0..<2 {
          frames[index]["sequenceNumber"] = index
          frames[index]["hostTimeSeconds"] = index * 2
          var timestamp = try XCTUnwrap(frames[index]["timestamp"] as? [String: Any])
          timestamp["value"] = index * 2
          frames[index]["timestamp"] = timestamp
        }
        value["frames"] = frames
        value["clockCorrelation"] = [
          "hostBeforeSeconds": 0, "hostAfterSeconds": 0, "bootTimeSeconds": 0, "method": "fixture",
        ]
        value["motionSamples"] = [0, 2].map { time in
          [
            "bootTimeSeconds": time, "attitude": ["x": 0, "y": 0, "z": 0, "w": 1],
            "rotationRate": ["x": 0, "y": 0, "z": 0], "gravity": ["x": 0, "y": 0, "z": -1],
            "userAcceleration": ["x": 0, "y": 0, "z": 0], "referenceFrame": "fixture",
          ] as [String: Any]
        }
      }
    }

    private func modified(
      _ evidence: DocumentTemporalEvidence, _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> DocumentTemporalEvidence {
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence.manifest))
          as? [String: Any])
      object["sequenceID"] = UUID().uuidString
      try mutation(&object)
      let observation = try JSONDecoder().decode(
        DocumentTemporalManifest.self, from: JSONSerialization.data(withJSONObject: object))
      let payload = try XCTUnwrap(evidence.frames.first?.payload)
      return .init(
        manifest: observation,
        frames: observation.frames.map { .init(metadata: $0, payload: payload) })
    }

    private func evidence(
      for manifest: CaptureRecords.Manifest, corruptPayload: Bool = false
    ) -> DocumentTemporalEvidence {
      let pixels = Data([1, 2, 3, 4])
      let frame = DocumentTemporalFrameMetadata(
        sequenceNumber: 1, timestamp: manifest.captureTimestamp, hostTimeSeconds: nil,
        width: 1, height: 1, pixelFormat: 1,
        planes: [
          .init(
            offset: 0, byteCount: 4, width: 1, height: 1,
            sourceBytesPerRow: 4, packedBytesPerRow: 4)
        ],
        sha256: CaptureArtifactIntegrity.sha256(pixels), colorAttachmentsPlist: nil, geometry: nil,
        camera: nil)
      let observation = DocumentTemporalManifest(
        schemaVersion: 1, sequenceID: UUID(),
        binding: .init(
          sessionID: manifest.sessionID.rawValue.uuidString,
          attemptID: manifest.captureID.uuidString,
          side: manifest.profile.side.rawValue, stillSHA256: manifest.fidelity.sha256,
          stillTimestamp: manifest.captureTimestamp, stillHostTimeSeconds: nil),
        configuration: .init(enabled: true), frames: [frame], motionSamples: [],
        clockCorrelation: nil, status: "partial", termination: "fixture", issues: ["no_motion"],
        gaps: [], omittedDiagnosticCount: 0, evictedFrameCount: 0, evictedMotionSampleCount: 0)
      return .init(
        manifest: observation,
        frames: [.init(metadata: frame, payload: corruptPayload ? Data([9]) : pixels)])
    }
  }
#endif
