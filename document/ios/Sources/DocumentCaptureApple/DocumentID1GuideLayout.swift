import Foundation

package struct DocumentID1GuideLayout: Equatable, Sendable {
  static let aspectRatio = ID1CardGeometry.widthMillimeters / ID1CardGeometry.heightMillimeters

  let horizontalInset: Double
  let verticalInset: Double
  let maximumWidth: Double

  package init(
    horizontalInset: Double = DocumentCaptureDefaults.guideHorizontalInset,
    verticalInset: Double = DocumentCaptureDefaults.guideVerticalInset,
    maximumWidth: Double = DocumentCaptureDefaults.guideMaximumWidth
  ) {
    self.horizontalInset = horizontalInset
    self.verticalInset = verticalInset
    self.maximumWidth = maximumWidth
  }

  package func guideFrame(in bounds: CGRect) -> CGRect? {
    guard
      bounds.minX.isFinite,
      bounds.minY.isFinite,
      bounds.width.isFinite,
      bounds.height.isFinite,
      horizontalInset.isFinite,
      verticalInset.isFinite,
      maximumWidth.isFinite,
      bounds.width > 0,
      bounds.height > 0,
      horizontalInset >= 0,
      verticalInset >= 0,
      maximumWidth > 0
    else { return nil }

    let availableWidth = bounds.width - (horizontalInset * 2)
    let availableHeight = bounds.height - (verticalInset * 2)
    guard availableWidth > 0, availableHeight > 0 else { return nil }

    let width = min(maximumWidth, availableWidth, availableHeight * Self.aspectRatio)
    let height = width / Self.aspectRatio
    guard width > 0, height > 0 else { return nil }

    return CGRect(
      x: bounds.midX - (width / 2),
      y: bounds.midY - (height / 2),
      width: width,
      height: height
    )
  }
}
