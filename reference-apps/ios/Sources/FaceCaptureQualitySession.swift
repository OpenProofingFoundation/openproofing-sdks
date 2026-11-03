import BiometricCapture
import BiometricQuality
import Foundation

/// App-owned effect port. The live adapter consumes the actual local SDK assessor.
protocol FaceCaptureQualitySession: Sendable {
    func assess(_ snapshot: SelfiePixelSnapshot) async throws -> FaceCaptureSelectionRecord.Quality
    func close() async
}

struct NativeFaceCaptureQualitySession: FaceCaptureQualitySession {
    private let engine: OFIQFaceQuality
    init(directory: URL) throws {
        #if os(iOS)
        let bundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard directory.isFileURL,
              directory.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(bundle) else { throw FaceQualityFailure.invalidAssets }
        #endif
        engine = try OFIQFaceQuality(assetDirectory: directory)
    }
    func assess(_ snapshot: SelfiePixelSnapshot) async throws -> FaceCaptureSelectionRecord.Quality {
        let assessment = try await engine.assess(snapshot.pixels, sourceSHA256: snapshot.sourceEncodedSHA256)
        guard assessment.sourceSHA256 == snapshot.sourceEncodedSHA256, assessment.rasterSHA256 == snapshot.pixels.sha256,
              assessment.width == snapshot.pixels.width, assessment.height == snapshot.pixels.height else { throw FaceCaptureSelectionFailure.source }
        return .init(sourceSHA256: assessment.sourceSHA256, rasterSHA256: assessment.rasterSHA256,
            artifactManifestSHA256: assessment.artifactManifestSHA256, returnCode: assessment.returnCode, faceCount: assessment.faceCount,
            components: assessment.components.map { .init(measureID: $0.measureID, code: $0.code, native: $0.native, mapped: $0.mapped) })
    }
    func close() async { await engine.close() }
}
