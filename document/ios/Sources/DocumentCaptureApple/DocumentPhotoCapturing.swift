import DocumentSDK

@MainActor
public protocol DocumentPhotoCapturing: AnyObject {
  var sessionID: CaptureSessionID { get }

  func start() async throws
  func stop()
  func capture(request: DocumentCaptureRequest) async throws -> CapturedDocumentPhoto
}

extension DocumentPhotoCapturing {
  public func capture(side: DocumentSide) async throws -> CapturedDocumentPhoto {
    try await capture(request: DocumentCaptureRequest(side: side))
  }
}
