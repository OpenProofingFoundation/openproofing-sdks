#if os(iOS)
  import UIKit

  /// Visual acquisition band; the preview supplies its camera-space bounds for automatic MRZ admission.
  public struct MRZPreviewGuide: Sendable {
    public let bandHeight: CGFloat
    public let horizontalInset: CGFloat
    public let cornerRadius: CGFloat
    public let veilOpacity: CGFloat

    public init(
      bandHeight: CGFloat, horizontalInset: CGFloat, cornerRadius: CGFloat,
      veilOpacity: CGFloat
    ) {
      self.bandHeight = bandHeight
      self.horizontalInset = horizontalInset
      self.cornerRadius = cornerRadius
      self.veilOpacity = veilOpacity
    }

    /// Geometry ported from Pulse's device-tested MRZCapture viewfinder on 2026-10-07.
    /// This matches its short, wide MRZ band and surrounding veil; hosts own all instructions.
    public static let documentBand = Self(
      bandHeight: 110, horizontalInset: 24, cornerRadius: 12, veilOpacity: 0.65)

    func frame(in bounds: CGRect) -> CGRect {
      let inset = min(max(0, horizontalInset), bounds.width / 2)
      let height = min(max(0, bandHeight), bounds.height)
      return CGRect(
        x: bounds.minX + inset, y: bounds.midY - height / 2,
        width: max(0, bounds.width - inset * 2), height: height)
    }
  }
#endif
