import CryptoKit
import Foundation
import Testing

@testable import DocumentCaptureApple

@Test
func retainedID1ReplayKeepsOriginalAndProducesRepeatableCoordinates() async throws {
  let directory = URL(
    fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["IDENTITY_EVIDENCE_ID1_REPLAY"]))
  struct Index: Decodable { let latestCaptureID: UUID }
  struct Manifest: Decodable {
    let fidelity: PhotoFidelityMetadata
    let admission: DocumentCaptureAdmissionSnapshot?
  }
  let index = try JSONDecoder().decode(
    Index.self, from: Data(contentsOf: directory.appendingPathComponent("index.json")))
  let record = directory.appendingPathComponent(index.latestCaptureID.uuidString)
  let original = try Data(contentsOf: record.appendingPathComponent("original.bin"))
  let manifest = try JSONDecoder().decode(
    Manifest.self, from: Data(contentsOf: record.appendingPathComponent("manifest.json")))
  let sourceHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
  #expect(sourceHash == manifest.fidelity.sha256)
  let preparer = AppleDocumentImagePreparer()
  let result = try await preparer.prepareRetained(
    data: original, side: .front,
    fidelity: manifest.fidelity, admission: manifest.admission)
  let repeated = try await preparer.prepareRetained(
    data: original, side: .front,
    fidelity: manifest.fidelity, admission: manifest.admission)
  #expect(result.derivative.derivation.supported)
  #expect(result.derivative.derivation.id1Geometry != nil)
  #expect(result.derivative.data == repeated.derivative.data)
  #expect(result.derivative.derivation == repeated.derivative.derivation)
  #expect(try Data(contentsOf: record.appendingPathComponent("original.bin")) == original)
  let output = directory.appendingPathComponent("id1-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
  try result.derivative.data.write(to: output.appendingPathComponent("normalized.png"))
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(result.derivative.derivation).write(
    to: output.appendingPathComponent("geometry.json"))
  print("ID1_REPLAY_OUTPUT " + output.path)
}
