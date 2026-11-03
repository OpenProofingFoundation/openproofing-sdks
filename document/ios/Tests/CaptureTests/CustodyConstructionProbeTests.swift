#if os(iOS)
  import XCTest
  import Foundation
  import CryptoKit
  @_spi(CaptureTestFixture) @testable import CaptureEvidenceCustody
  final class CustodyConstructionProbeTests: XCTestCase {
    func testRuntimeConstructionStages() throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      let config = try CaptureCustodyConfiguration(
      applicationID: "synthetic.capture-sdk.fixture", directory: directory,
        keychainService: "synthetic." + UUID().uuidString, keychainAccount: "probe", accessGroup: "TEST.capture-sdk.fixture")
      // Explicit synthetic construction checks file/runtime stages without claiming platform keys.
      let key = SymmetricKey(size: .bits256)
      defer {
        try? CaptureCustodyRuntime.testingRemoveKey(configuration: config)
        try? FileManager.default.removeItem(at: directory)
      }
      do {
        try FileManager.default.createDirectory(
          at: config.directory, withIntermediateDirectories: true)
      } catch {
        XCTFail("directory stage: \(error)")
        return
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: config.directory.path))
      do {
        var excluded = config.directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try excluded.setResourceValues(resources)
      } catch {
        XCTFail("resource stage: \(error)")
        return
      }
      do { _ = try CaptureEvidenceStore(directory: config.directory, key: key) } catch {
        XCTFail("store stage: \(error)")
        return
      }
      do { _ = try CaptureCustodyRuntime.testing(configuration: config) } catch {
        XCTFail("runtime stage: \(error)")
        return
      }
    }
  }
#endif
