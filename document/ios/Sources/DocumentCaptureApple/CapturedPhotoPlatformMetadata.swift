import Foundation
import ImageIO

/// Every platform metadata value retained for one capture, kept whole rather
/// than curated.
///
/// `PhotoFidelityMetadata` stays a small typed subset for code that reads
/// specific facts. This record exists so nothing the platform reported is
/// discarded, including the Apple maker note, which carries values the SDK does
/// not model — among them the capture-time accelerometer vector and the
/// device's own capture identifiers.
///
/// Retaining metadata is provenance, not verification. Any of these values can
/// be rewritten in a file by anyone holding it; what makes the retained copy
/// trustworthy is that the SDK read it from bytes it received in-process and
/// bound it to their digest.
public struct CapturedPhotoPlatformMetadata: Codable, Equatable, Sendable {
  /// `AVCapturePhoto.metadata` as the platform reported it before file
  /// encoding, serialized as a binary property list.
  ///
  /// Recorded separately from the encoded file's own properties because the
  /// encoder may drop or transform values on the way into the container.
  public let captureMetadataPlist: Data?

  /// The complete `CGImageSourceCopyPropertiesAtIndex` dictionary read back
  /// from the retained encoded bytes, serialized as a binary property list.
  public let encodedPropertiesPlist: Data?

  /// Auxiliary image types the retained bytes carry.
  ///
  /// The auxiliary images themselves are already inside the retained original
  /// and covered by its digest, so this names them rather than copying them.
  public let auxiliaryDataTypes: [String]

  /// Top-level keys whose values the property-list format could not represent
  /// and which were therefore dropped from the retained plists.
  ///
  /// Empty means nothing was dropped. A named key distinguishes a value this
  /// record could not keep from one the platform never reported.
  public let unrepresentableKeys: [String]

  public init(
    captureMetadataPlist: Data?,
    encodedPropertiesPlist: Data?,
    auxiliaryDataTypes: [String],
    unrepresentableKeys: [String] = []
  ) {
    self.captureMetadataPlist = captureMetadataPlist
    self.encodedPropertiesPlist = encodedPropertiesPlist
    self.auxiliaryDataTypes = auxiliaryDataTypes
    self.unrepresentableKeys = unrepresentableKeys
  }

  /// The name recorded in `auxiliaryDataTypes` for an HDR gain map.
  ///
  /// `PhotoFidelityMetadata` reads its own gain-map fact from the same probe
  /// rather than repeating it, so the name is shared instead of duplicated.
  static let hdrGainMapAuxiliaryName = "HDRGainMap"

  /// A serialized metadata dictionary and the keys that could not be kept.
  struct Serialized: Equatable, Sendable {
    let data: Data?
    let droppedKeys: [String]

    static let none = Self(data: nil, droppedKeys: [])
  }

  /// Serializes a platform-supplied metadata dictionary for retention,
  /// dropping only the entries the binary property-list format cannot
  /// represent and naming them.
  ///
  /// Whole-dictionary validation would discard everything over one
  /// unrepresentable value, including the Apple maker note this record exists
  /// to keep, and that loss would be indistinguishable from the platform
  /// reporting nothing. Dropping is per top-level key: a container holding one
  /// unrepresentable leaf is dropped and named rather than silently reshaped.
  ///
  /// Never throws. Losing metadata is not a reason to lose an otherwise
  /// retained original.
  static func serialize(_ metadata: [String: Any]) -> Serialized {
    guard !metadata.isEmpty else { return .none }
    var retained: [String: Any] = [:]
    var dropped: [String] = []
    for (key, value) in metadata {
      // Probed inside a single-key dictionary so the check always has a valid
      // root container and only the value's representability is in question.
      if PropertyListSerialization.propertyList([key: value], isValidFor: .binary) {
        retained[key] = value
      } else {
        dropped.append(key)
      }
    }
    guard
      !retained.isEmpty,
      let data = try? PropertyListSerialization.data(
        fromPropertyList: retained, format: .binary, options: 0)
    else { return Serialized(data: nil, droppedKeys: dropped.sorted()) }
    return Serialized(data: data, droppedKeys: dropped.sorted())
  }

  /// Builds the record from one already-read image source's outputs.
  ///
  /// The properties dictionary and auxiliary probe are supplied rather than
  /// re-read: reading them costs a full property copy and materializes each
  /// auxiliary image's payload, so the capture path performs both once and
  /// shares the result.
  static func make(
    properties: [CFString: Any]?,
    auxiliaryDataTypes: [String],
    captureMetadata: Serialized
  ) -> Self {
    let encoded = properties.map(serialize(properties:)) ?? .none
    return Self(
      captureMetadataPlist: captureMetadata.data,
      encodedPropertiesPlist: encoded.data,
      auxiliaryDataTypes: auxiliaryDataTypes,
      unrepresentableKeys: Set(captureMetadata.droppedKeys + encoded.droppedKeys).sorted())
  }

  /// Convenience for callers that hold only bytes. The capture path uses
  /// `make(properties:auxiliaryDataTypes:captureMetadata:)` instead so it reads
  /// the bytes once.
  static func make(encoded data: Data, captureMetadata: Serialized) -> Self {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return make(properties: nil, auxiliaryDataTypes: [], captureMetadata: captureMetadata)
    }
    return make(
      properties: encodedProperties(of: source),
      auxiliaryDataTypes: auxiliaryTypes(of: source),
      captureMetadata: captureMetadata)
  }

  /// The complete properties dictionary of the retained bytes, used for
  /// retention, for the curated subset, and to confirm whether a requested
  /// location was written.
  static func encodedProperties(of source: CGImageSource) -> [CFString: Any]? {
    CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
  }

  /// Names the auxiliary images present.
  ///
  /// Each probe returns the auxiliary payload itself, so this is deliberately
  /// performed once per capture and its result shared.
  static func auxiliaryTypes(of source: CGImageSource) -> [String] {
    let probed: [(name: String, type: CFString)] = [
      (hdrGainMapAuxiliaryName, kCGImageAuxiliaryDataTypeHDRGainMap),
      ("Depth", kCGImageAuxiliaryDataTypeDepth),
      ("Disparity", kCGImageAuxiliaryDataTypeDisparity),
      ("PortraitEffectsMatte", kCGImageAuxiliaryDataTypePortraitEffectsMatte)
    ]
    return probed.compactMap { candidate in
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, candidate.type) == nil
        ? nil : candidate.name
    }
  }

  private static func serialize(properties: [CFString: Any]) -> Serialized {
    var bridged: [String: Any] = [:]
    for (key, value) in properties {
      bridged[key as String] = value
    }
    return serialize(bridged)
  }
}
