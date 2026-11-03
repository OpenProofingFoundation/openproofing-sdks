import Testing

@testable import DocumentCaptureApple

@Test
func previewFailedRefreshCannotRepublishPriorRotation() {
  var authority = DocumentPreviewGeometryAuthority()
  let initialAccepted = authority.invalidate(for: 4)
  #expect(initialAccepted)
  authority.acceptRotation(.portrait)
  #expect(authority.canPublishGuide)

  authority.beginRefresh()
  // A missing connection or unsupported angle never calls acceptRotation.
  #expect(!authority.canPublishGuide)
  #expect(authority.orientation == nil)
}

@Test
func previewSourceReplacementRequiresNewRotationAtUnchangedOrientation() {
  var authority = DocumentPreviewGeometryAuthority()
  let initialAccepted = authority.invalidate(for: 4)
  #expect(initialAccepted)
  authority.acceptRotation(.portrait)
  let replacementAccepted = authority.invalidate(for: 5)
  #expect(replacementAccepted)
  #expect(!authority.canPublishGuide)
  #expect(authority.sourceGeneration == 5)

  authority.acceptRotation(.portrait)
  #expect(authority.canPublishGuide)
  let staleAccepted = authority.invalidate(for: 4)
  #expect(!staleAccepted)
  #expect(authority.sourceGeneration == 5)
  #expect(authority.canPublishGuide)
}

@Test
func previewWithoutSourceEpochCannotAuthorizeGuide() {
  var authority = DocumentPreviewGeometryAuthority()
  authority.acceptRotation(.landscapeRight)
  #expect(!authority.canPublishGuide)
  #expect(authority.orientation == nil)
}
