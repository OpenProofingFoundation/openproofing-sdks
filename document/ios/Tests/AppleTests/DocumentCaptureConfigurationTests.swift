import AVFoundation
import Foundation
import Testing

@testable import DocumentCaptureApple

@Test func everyDocumentConfigurationUsesGeometryCapture() {
  #expect(DocumentCaptureConfiguration() == .geometry)
  for configuration in [
    DocumentCaptureConfiguration(), .geometry,
    DocumentCaptureConfiguration(encoding: .jpeg, distortionCorrection: .systemDefault)
  ] {
    let policy = AVFoundationDocumentCapturePolicy(configuration: configuration)
    let settings = policy.makePhotoSettings(photoOutput: AVCapturePhotoOutput())
    #expect(settings.photoQualityPrioritization == .balanced)
  }
}

@Test func geometryCapturePreservesEncodingAndDistortionChoices() {
  let configuration = DocumentCaptureConfiguration.geometry
  #expect(configuration.encoding == .heicWithJPEGFallback)
  #expect(configuration.distortionCorrection == .disabled)
  let jpeg = DocumentCaptureConfiguration(encoding: .jpeg)
  #expect(jpeg.encoding == .jpeg)
}
