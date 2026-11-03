import CryptoKit
import Foundation
import ImageIO

public struct PhotoFidelityMetadata: Codable, Equatable, Sendable {
  /// Platform-reported optical state of one still, recorded without
  /// interpretation.
  ///
  /// This is provenance, not calibration. The SDK does not request or record
  /// an intrinsic matrix, a lens-distortion model, or a subject distance, so
  /// nothing here converts a pixel offset into a physical dimension.
  public struct OpticalState: Codable, Equatable, Sendable {
    /// Recorded focal length in millimetres, and its 35 mm-film equivalent.
    ///
    /// Together with the recorded pixel dimensions these are the only values
    /// from which an approximate pinhole focal length in pixels can later be
    /// reconstructed.
    public let focalLengthMillimeters: Double?
    public let focalLengthIn35mmFilm: Double?

    /// EXIF `LensSpecification`: minimum focal length, maximum focal length,
    /// minimum f-number at the minimum focal length, and minimum f-number at
    /// the maximum focal length. On a virtual device this identifies the
    /// constituent range, which `lensModel` reports only as display text.
    public let lensSpecification: [Double]?

    /// Centered crop and resample applied by the platform before delivery. A
    /// value above 1 reports that the recorded pixels are not the full active
    /// format and have already been resampled once.
    public let digitalZoomRatio: Double?

    /// Raw EXIF `CompositeImage` value. A value other than 1 reports that the
    /// platform combined more than one source frame, so the recorded pixels
    /// are not a single exposure. No code infers a frame count from it.
    public let compositeImage: Int?

    /// Whether an HDR gain-map auxiliary image accompanies the still.
    ///
    /// Read through the documented auxiliary-data type rather than the
    /// undocumented top-level `Headroom` property, and in preference to
    /// `CGImageGetContentHeadroom`, which is unavailable at this SDK's
    /// deployment floor. Derived from the capture path's single auxiliary
    /// probe, not a second one.
    public let hdrGainMapPresent: Bool
  }

  public let pixelWidth: Int
  public let pixelHeight: Int
  public let fileByteCount: Int
  public let uniformTypeIdentifier: String
  public let orientation: Int?
  public let cameraModel: String?
  public let lensModel: String?
  public let exposureTimeSeconds: Double?
  public let fNumber: Double?
  public let isoSpeed: Double?
  public let sha256: String
  /// Nil on records retained before optical state was recorded.
  public let optical: OpticalState?

  static func make(from data: Data) throws -> Self {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CapturedPhotoPlatformMetadata.encodedProperties(of: source)
    else {
      throw PhotoCaptureError.imageMetadataUnavailable
    }
    return try make(
      from: data,
      source: source,
      properties: properties,
      auxiliaryDataTypes: CapturedPhotoPlatformMetadata.auxiliaryTypes(of: source))
  }

  /// Builds the curated subset from one already-read image source's outputs.
  ///
  /// The capture path reads the bytes once and shares the source, its property
  /// dictionary and its auxiliary probe across every record it assembles.
  static func make(
    from data: Data,
    source: CGImageSource,
    properties: [CFString: Any],
    auxiliaryDataTypes: [String]
  ) throws -> Self {
    guard
      let width = number(in: properties, for: kCGImagePropertyPixelWidth)?.intValue,
      let height = number(in: properties, for: kCGImagePropertyPixelHeight)?.intValue
    else {
      throw PhotoCaptureError.imageMetadataUnavailable
    }

    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let isoValues = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

    return Self(
      pixelWidth: width,
      pixelHeight: height,
      fileByteCount: data.count,
      uniformTypeIdentifier: (CGImageSourceGetType(source) as String?) ?? "unknown",
      orientation: number(in: properties, for: kCGImagePropertyOrientation)?.intValue,
      cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
      lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
      exposureTimeSeconds: number(in: exif, for: kCGImagePropertyExifExposureTime)?.doubleValue,
      fNumber: number(in: exif, for: kCGImagePropertyExifFNumber)?.doubleValue,
      isoSpeed: isoValues?.first?.doubleValue,
      sha256: digest,
      optical: opticalState(exif: exif, auxiliaryDataTypes: auxiliaryDataTypes)
    )
  }

  private static func opticalState(
    exif: [CFString: Any]?,
    auxiliaryDataTypes: [String]
  ) -> OpticalState {
    let lensValues = exif?[kCGImagePropertyExifLensSpecification] as? [NSNumber]
    let focal35 = number(in: exif, for: kCGImagePropertyExifFocalLenIn35mmFilm)?.doubleValue
    return OpticalState(
      focalLengthMillimeters: number(in: exif, for: kCGImagePropertyExifFocalLength)?.doubleValue,
      focalLengthIn35mmFilm: focal35,
      lensSpecification: lensValues.map { $0.map(\.doubleValue) },
      digitalZoomRatio: number(in: exif, for: kCGImagePropertyExifDigitalZoomRatio)?.doubleValue,
      compositeImage: number(in: exif, for: kCGImagePropertyExifCompositeImage)?.intValue,
      hdrGainMapPresent: auxiliaryDataTypes.contains(
        CapturedPhotoPlatformMetadata.hdrGainMapAuxiliaryName)
    )
  }

  private static func number(
    in dictionary: [CFString: Any]?,
    for key: CFString
  ) -> NSNumber? {
    dictionary?[key] as? NSNumber
  }
}
