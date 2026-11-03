import Darwin
import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Test func nativeFingerprintMatchesLegacyFoundationMetadataIncludingNanoseconds() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("synthetic.evidence")
  try Data([1, 2, 3]).write(to: path)
  for seconds in [0, 978_307_200, 1_789_500_000, 2_524_608_000] {
    for nanos in [0, 1, 123_456_789, 500_000_001, 999_999_999] {
      var times = [
        timespec(tv_sec: seconds, tv_nsec: nanos), timespec(tv_sec: seconds, tv_nsec: nanos),
      ]
      let result = path.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }
      #expect(result == 0)
      try assertFoundationFingerprint(path)
    }
  }
}

@Test func nativeFingerprintPreservesSymbolicLinkSemanticsAndErrors() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appendingPathComponent("target")
  let link = directory.appendingPathComponent("link.evidence")
  try Data(repeating: 3, count: 1_024).write(to: target)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  try assertFoundationFingerprint(link)
  let prior = try CaptureEvidenceIndex.Fingerprint(url: link)
  try FileManager.default.removeItem(at: target)
  #expect(try CaptureEvidenceIndex.Fingerprint(url: link) == prior)
  try assertFoundationFingerprint(link)
  #expect(throws: (any Error).self) { try CaptureEvidenceIndex.Fingerprint(url: target) }
}

private func assertFoundationFingerprint(_ path: URL) throws {
  let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
  let oldDate = try #require(attributes[.modificationDate] as? Date)
  let fields: [String: Any] = [
    "size": try #require(attributes[.size] as? NSNumber),
    "modified": oldDate.timeIntervalSinceReferenceDate,
    "fileNumber": try #require(attributes[.systemFileNumber] as? NSNumber),
  ]
  let bytes = try JSONSerialization.data(withJSONObject: fields)
  let legacy = try JSONDecoder().decode(CaptureEvidenceIndex.Fingerprint.self, from: bytes)
  #expect(try CaptureEvidenceIndex.Fingerprint(url: path) == legacy)
}
