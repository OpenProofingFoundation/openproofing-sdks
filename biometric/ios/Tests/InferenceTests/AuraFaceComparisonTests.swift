import XCTest
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import BiometricInference

final class AuraFaceComparisonTests: XCTestCase {
    func testSubstitutedSourceRejectedBeforeModelAccess() async throws {
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        do {
            _ = try await engine.compare(reference: Data([1]), referenceSHA256: String(repeating: "0", count: 64),
                                         selfie: Data([1]), selfieSHA256: String(repeating: "0", count: 64))
            XCTFail("Substitution must fail")
        } catch { XCTAssertEqual(error as? FaceInferenceFailure, .sourceMismatch) }
    }
    func testMalformedImageRejectedBeforeModelAccess() async throws {
        let data = Data([1,2,3])
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        do {
            _ = try await engine.compare(reference: data, referenceSHA256: digest(data), selfie: data, selfieSHA256: digest(data))
            XCTFail("Malformed encoding must fail")
        } catch { XCTAssertEqual(error as? FaceInferenceFailure, .invalidImage) }
    }
    func testEmptyImageRejected() async throws {
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        do {
            _ = try await engine.compare(reference: Data(), referenceSHA256: digest(Data()), selfie: Data(), selfieSHA256: digest(Data()))
            XCTFail("Empty image must fail")
        } catch { XCTAssertEqual(error as? FaceInferenceFailure, .resourceLimit) }
    }
    func testBlankImageDoesNotProduceSimilarity() async throws {
        let data = try blankPNG()
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        do {
            _ = try await engine.compare(reference: data, referenceSHA256: digest(data), selfie: data, selfieSHA256: digest(data))
            XCTFail("An image without a face must not produce an embedding")
        } catch { XCTAssertEqual(error as? FaceInferenceFailure, .faceMissing) }
    }
    func testPreflightRejectsSubstitutedSourceWithoutModelAccess() async throws {
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        do {
            _ = try await engine.preflight(image: Data([1]), sourceSHA256: String(repeating: "0", count: 64))
            XCTFail("Preflight must bind the exact source")
        } catch { XCTAssertEqual(error as? FaceInferenceFailure, .sourceMismatch) }
    }
    func testPreflightRejectsMalformedImageWithoutModelAccess() async throws {
        let data = Data([1, 2, 3])
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        do {
            _ = try await engine.preflight(image: data, sourceSHA256: digest(data))
            XCTFail("Malformed pixels must not become a prepared candidate")
        } catch { XCTAssertEqual(error as? FaceInferenceFailure, .invalidImage) }
    }
    func testPreflightRejectsEmptyAndOversizedEncodingBeforeSourceHash() async throws {
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        for data in [Data(), Data(repeating: 0, count: 33_554_433)] {
            do {
                _ = try await engine.preflight(image: data, sourceSHA256: "invalid")
                XCTFail("Encoding resource limits must precede hashing or model access")
            } catch { XCTAssertEqual(error as? FaceInferenceFailure, .resourceLimit) }
        }
    }
    func testPreflightRejectsOversizedDimensionsBeforeFaceDetection() async throws {
        let data = try blankPNG(width: 4097, height: 1)
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        do {
            _ = try await engine.preflight(image: data, sourceSHA256: digest(data))
            XCTFail("Dimension limits must precede Vision and native allocation")
        } catch { XCTAssertEqual(error as? FaceInferenceFailure, .resourceLimit) }
    }
    func testPreflightRejectsNoFaceWithoutRequiringEmbeddingModel() async throws {
        let data = try blankPNG()
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        do {
            _ = try await engine.preflight(image: data, sourceSHA256: digest(data))
            XCTFail("No-face input must not become a prepared candidate")
        } catch { XCTAssertEqual(error as? FaceInferenceFailure, .faceMissing) }
    }
    func testCancelledPreflightRefusesBeforeSourceProcessing() async throws {
        let engine = AuraFaceComparison(modelURL: URL(fileURLWithPath: "/absent/model.onnx"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.preflight(image: Data(), sourceSHA256: "invalid")
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must not publish a prepared candidate")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func blankPNG(width: Int = 112, height: Int = 112) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
