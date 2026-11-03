import BiometricSDK
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public enum SelfiePixelFailure: String, Error, Sendable {
  case invalidEncoding = "invalid_encoding"
  case resourceLimit = "resource_limit"
  case sourceMismatch = "source_mismatch"
  case unsupportedOrientation = "unsupported_orientation"
  case decodingFailed = "decoding_failed"
}

/// Encoded-source and decoded-pixel identities remain distinct. This is decoding,
/// not face selection, alignment, PAD or an authenticity decision.
public struct SelfiePixelSnapshot: Sendable {
  public let sourceEncodedSHA256: String
  public let pixels: PortraitPixels
  public let derivationProfile: String
  public let colorSpace: String
  public let alphaConversion: String
  public let interpolation: String
}

/// Capture decoder engineering resource profile v1. These are allocation ceilings,
/// not biometric policy or a measured physical-device memory budget. Eight MP
/// supports 3840x2160 frames; dimensions and encoded bytes have independent bounds.
/// RGBA + packed RGB + defensive snapshot copies conservatively remain below
/// 200 MiB of application-owned raster storage, excluding ImageIO decoder storage.
private struct SelfiePixelResources {
  let maximumDimension: Int
  let maximumPixels: Int
  let maximumEncodedBytes: Int
  static let captureV1 = Self(maximumDimension: 4096, maximumPixels: 8_388_608,
    maximumEncodedBytes: 33_554_432)
}

public enum SelfiePixelBridge {
  /// This input has already been physically oriented by capture. Embedded rotations
  /// are refused rather than applied a second time. Rows are top-to-bottom RGB8.
  public static func decodeOrientedPNG(
    _ encodedPNG: Data, expectedSourceSHA256: String
  ) throws -> SelfiePixelSnapshot {
    guard !encodedPNG.isEmpty, encodedPNG.count <= SelfiePixelResources.captureV1.maximumEncodedBytes else {
      throw SelfiePixelFailure.resourceLimit
    }
    let owned = Data(Array(encodedPNG))
    let sourceDigest = digest(owned)
    guard sourceDigest == expectedSourceSHA256 else { throw SelfiePixelFailure.sourceMismatch }
    guard owned.count >= 33,
      owned.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
      Array(owned[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else {
      throw SelfiePixelFailure.invalidEncoding
    }
    // Bound the fixed PNG IHDR before ImageIO receives the compressed image.
    // ImageIO independently validates the container and decoded dimensions below.
    let declaredWidth = dimension(owned, at: 16)
    let declaredHeight = dimension(owned, at: 20)
    try requireDimensions(width: declaredWidth, height: declaredHeight)
    guard let source = CGImageSourceCreateWithData(owned as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetType(source) as String? == "public.png",
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetStatus(source) == .statusComplete,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0 else { throw SelfiePixelFailure.invalidEncoding }
    guard width == declaredWidth, height == declaredHeight else {
      throw SelfiePixelFailure.invalidEncoding
    }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    guard orientation == 1 else { throw SelfiePixelFailure.unsupportedOrientation }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      image.width == width, image.height == height,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw SelfiePixelFailure.decodingFailed
    }
    // Explicit big-endian premultiplied RGBA over transparent black. Dropping
    // premultiplied alpha therefore composites over black without unpremultiplying.
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
      guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { throw SelfiePixelFailure.decodingFailed }
    var rgb = [UInt8]()
    rgb.reserveCapacity(width * height * 3)
    for offset in stride(from: 0, to: rgba.count, by: 4) {
      rgb.append(contentsOf: rgba[offset..<(offset + 3)])
    }
    let pixels = try PortraitPixels(layout: .init(width: width, height: height, format: "rgb8",
      rowStrideBytes: width * 3, byteLength: rgb.count, orientation: 1),
      sha256: digest(Data(rgb)), bytes: rgb)
    return SelfiePixelSnapshot(sourceEncodedSHA256: sourceDigest, pixels: pixels,
      derivationProfile: "apple-imageio-srgb-rgb8-oriented-png-v1", colorSpace: "srgb",
      alphaConversion: "premultiplied_over_black", interpolation: "none")
  }

  private static func dimension(_ data: Data, at offset: Int) -> Int {
    data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
  }

  private static func requireDimensions(width: Int, height: Int) throws {
    guard width > 0, height > 0 else { throw SelfiePixelFailure.invalidEncoding }
    guard width <= SelfiePixelResources.captureV1.maximumDimension, height <= SelfiePixelResources.captureV1.maximumDimension,
      width <= SelfiePixelResources.captureV1.maximumPixels / height else {
      throw SelfiePixelFailure.resourceLimit
    }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
