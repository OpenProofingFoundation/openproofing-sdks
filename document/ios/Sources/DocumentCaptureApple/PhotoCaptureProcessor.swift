import AVFoundation
import Foundation
import DocumentSDK

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
  private let admission: DocumentCaptureAdmissionSnapshot
  private let assembler: CapturedDocumentPhotoAssembler
  private let locationAssertion: CaptureLocationAssertion?
  private let completion:
    @Sendable (
      Result<CapturedDocumentPhoto, PhotoCaptureError>
    ) -> Void
  private let lock = NSLock()
  private var processingResult: Result<CapturedDocumentPhoto, PhotoCaptureError>?
  private var didComplete = false

  init(
    assembler: CapturedDocumentPhotoAssembler,
    admission: DocumentCaptureAdmissionSnapshot,
    locationAssertion: CaptureLocationAssertion? = nil,
    completion:
      @escaping @Sendable (
        Result<CapturedDocumentPhoto, PhotoCaptureError>
      ) -> Void
  ) {
    self.admission = admission
    self.assembler = assembler
    self.locationAssertion = locationAssertion
    self.completion = completion
  }

  func photoOutput(
    _ _: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: (any Error)?
  ) {
    let result: Result<CapturedDocumentPhoto, PhotoCaptureError>

    let hasMismatchedResult =
      photo.resolvedSettings.uniqueID != admission.photoSettingsUniqueID
      || photo.resolvedSettings.expectedPhotoCount != 1
      || photo.photoCount != 1
    if hasMismatchedResult {
      result = .failure(.captureIdentityMismatch)
    } else if let error {
      result = .failure(.captureFailed(String(describing: error)))
    } else if let captureTimestamp = DocumentCaptureClockTimestamp(
      avCapturePhotoTimestamp: photo.timestamp
    ) {
      guard let data = photo.fileDataRepresentation() else {
        lock.withLock {
          processingResult = .failure(.encodedPhotoUnavailable)
        }
        return
      }
      do {
        result = .success(
          try assembler.assemble(
            data: data,
            sessionID: admission.sessionID,
            side: admission.side,
            captureTimestamp: captureTimestamp,
            requestedAt: admission.userRequestedAt,
            admission: admission,
            locationAssertion: locationAssertion,
            // Serialized here because `AVCapturePhoto.metadata` is not
            // `Sendable` and must not cross the delegate boundary.
            captureMetadata: captureMetadata(from: photo)
          )
        )
      } catch let error as PhotoCaptureError {
        result = .failure(error)
      } catch {
        result = .failure(.captureFailed(String(describing: error)))
      }
    } else {
      result = .failure(.captureTimestampUnavailable)
    }

    lock.withLock {
      processingResult = result
    }
  }

  func photoOutput(
    _ _: AVCapturePhotoOutput,
    didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
    error: (any Error)?
  ) {
    let result = lock.withLock { () -> Result<CapturedDocumentPhoto, PhotoCaptureError> in
      guard
        resolvedSettings.uniqueID == admission.photoSettingsUniqueID,
        resolvedSettings.expectedPhotoCount == 1
      else {
        return .failure(.captureIdentityMismatch)
      }
      if let error {
        return .failure(.captureFailed(String(describing: error)))
      }
      return processingResult ?? .failure(.encodedPhotoUnavailable)
    }
    finishOnce(with: result)
  }

  private func captureMetadata(from photo: AVCapturePhoto)
    -> CapturedPhotoPlatformMetadata.Serialized {
    #if os(macOS)
      return .none
    #else
      return CapturedPhotoPlatformMetadata.serialize(photo.metadata)
    #endif
  }

  private func finishOnce(
    with result: Result<CapturedDocumentPhoto, PhotoCaptureError>
  ) {
    let shouldComplete = lock.withLock { () -> Bool in
      guard !didComplete else { return false }
      didComplete = true
      return true
    }
    if shouldComplete {
      completion(result)
    }
  }
}
