import Foundation
import Testing

@testable import DocumentCaptureApple

@Test
func id1GuideIsCenteredWithExactAspectRatio() throws {
  let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
  let frame = try #require(DocumentID1GuideLayout().guideFrame(in: bounds))

  #expect(abs(frame.midX - bounds.midX) < 0.000_001)
  #expect(abs(frame.midY - bounds.midY) < 0.000_001)
  #expect(abs((frame.width / frame.height) - DocumentID1GuideLayout.aspectRatio) < 0.000_001)
  #expect(abs(frame.minX - 16) < 0.000_001)
}

@Test
func id1GuideHonorsMaximumWidth() throws {
  let frame = try #require(
    DocumentID1GuideLayout().guideFrame(
      in: CGRect(x: 0, y: 0, width: 1_200, height: 900)
    )
  )

  #expect(frame.width == 520)
}

@Test
func id1GuideFitsShortBoundsWithoutChangingAspect() throws {
  let bounds = CGRect(x: 0, y: 0, width: 844, height: 240)
  let frame = try #require(DocumentID1GuideLayout().guideFrame(in: bounds))

  #expect(abs(frame.minY - 16) < 0.000_001)
  #expect(abs(frame.maxY - (bounds.maxY - 16)) < 0.000_001)
  #expect(abs((frame.width / frame.height) - DocumentID1GuideLayout.aspectRatio) < 0.000_001)
}

@Test
func id1GuideRejectsInvalidBounds() {
  let layout = DocumentID1GuideLayout()
  #expect(layout.guideFrame(in: .zero) == nil)
  #expect(layout.guideFrame(in: CGRect(x: 0, y: 0, width: 31, height: 100)) == nil)
  #expect(layout.guideFrame(in: CGRect(x: 0, y: 0, width: 100, height: 31)) == nil)
  #expect(
    layout.guideFrame(
      in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)
    ) == nil
  )
  #expect(
    layout.guideFrame(
      in: CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan)
    ) == nil
  )
}

@Test
func id1GuideLayoutIsDeterministicAndRespondsToMaterialResize() throws {
  let layout = DocumentID1GuideLayout()
  let original = try #require(
    layout.guideFrame(in: CGRect(x: 0, y: 0, width: 390, height: 844))
  )
  let repeated = try #require(
    layout.guideFrame(in: CGRect(x: 0, y: 0, width: 390, height: 844))
  )
  let resized = try #require(
    layout.guideFrame(in: CGRect(x: 0, y: 0, width: 430, height: 844))
  )

  #expect(original == repeated)
  #expect(original != resized)
}
