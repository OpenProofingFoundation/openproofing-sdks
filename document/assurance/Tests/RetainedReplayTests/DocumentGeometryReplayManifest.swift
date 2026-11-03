import CoreVideo
import CryptoKit
import Foundation
import Testing

@testable import DocumentCaptureApple

/// Local test input only. The helper verifies the whole export; this loader rechecks every used byte.
struct DocumentGeometryReplayManifest: Decodable {
  struct Plane: Codable, Equatable {
    let width: Int
    let height: Int
    let packedBytesPerRow: Int
    let sourceBytesPerRow: Int
    let offset: Int
    let byteCount: Int
  }

  struct Pixels: Codable, Equatable {
    let width: Int
    let height: Int
    let pixelFormat: UInt32
    let timestamp: DocumentCaptureClockTimestamp
    let planes: [Plane]
    let colorAttachmentsPlist: Data?
    let sha256: String
  }

  struct Frame: Decodable {
    let sourceIndex: Int
    let recordID: UUID
    let manifestSHA256: String
    let originalSHA256: String
    let frame: Pixels
  }

  let schemaVersion: Int
  let exportRoot: String
  let exportIndexSHA256: String
  let recordingID: UUID
  let guide: DocumentCameraGuideRegion
  let guideProvenance: String
  let frames: [Frame]

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func validate() throws {
    #expect(schemaVersion == 1)
    _ = try #require(guide.normalizedTopLeftRect)
    #expect(!guideProvenance.isEmpty)
    #expect(!frames.isEmpty && frames.count <= 10_000)
    let index = try Data(
      contentsOf: URL(fileURLWithPath: exportRoot).appendingPathComponent("index.json"))
    try #require(Self.digest(index) == exportIndexSHA256)
  }

  func load(_ item: Frame) throws -> CVPixelBuffer {
    struct SourceManifest: Decodable { let frame: Pixels }
    let root = URL(fileURLWithPath: exportRoot).appendingPathComponent(item.recordID.uuidString)
    let metadata = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
    try #require(Self.digest(metadata) == item.manifestSHA256)
    let source = try JSONDecoder().decode(SourceManifest.self, from: metadata)
    try #require(source.frame == item.frame)
    let raw = try Data(contentsOf: root.appendingPathComponent("original.bin"))
    try #require(
      Self.digest(raw) == item.originalSHA256 && item.originalSHA256 == source.frame.sha256)
    return try Self.rehydrate(source.frame, raw: raw)
  }

  private static func rehydrate(_ metadata: Pixels, raw: Data) throws -> CVPixelBuffer {
    try #require(
      [
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ].contains(metadata.pixelFormat))
    try #require((1...8192).contains(metadata.width) && (1...8192).contains(metadata.height))
    try #require(metadata.planes.count == 2)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, metadata.width, metadata.height, metadata.pixelFormat, nil, &buffer)
    try #require(status == kCVReturnSuccess)
    let pixels = try #require(buffer)
    try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    try raw.withUnsafeBytes { bytes in
      let base = try #require(bytes.baseAddress)
      for (index, plane) in metadata.planes.enumerated() {
        try #require(plane.width == CVPixelBufferGetWidthOfPlane(pixels, index))
        try #require(plane.height == CVPixelBufferGetHeightOfPlane(pixels, index))
        try #require(plane.packedBytesPerRow == metadata.width && plane.offset >= 0)
        try #require(plane.byteCount == plane.height * plane.packedBytesPerRow)
        try #require(plane.offset <= raw.count && plane.byteCount <= raw.count - plane.offset)
        let destination = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, index))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, index)
        try #require(stride >= plane.packedBytesPerRow)
        for row in 0..<plane.height {
          destination.advanced(by: row * stride).copyMemory(
            from: base.advanced(by: plane.offset + row * plane.packedBytesPerRow),
            byteCount: plane.packedBytesPerRow)
        }
      }
    }
    if let data = metadata.colorAttachmentsPlist {
      let attachments = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
      CVBufferSetAttachments(pixels, attachments as CFDictionary, .shouldPropagate)
    }
    return pixels
  }
}
