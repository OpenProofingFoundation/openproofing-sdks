#if os(macOS)
  import Foundation
  import XCTest

  /// Compile real external consumers: testable fixtures must not accidentally become public APIs.
  final class CaptureCustodyPublicAPITests: XCTestCase {
    func testPublicConsumersMustOpenLeasedRuntimeInsteadOfRawKeysOrStores() throws {
      let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let sourceDirectory = root.appendingPathComponent("Sources/CaptureEvidenceCustody")
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let module = directory.appendingPathComponent("CaptureEvidenceCustody.swiftmodule")
      let sources = try FileManager.default.contentsOfDirectory(
        at: sourceDirectory, includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "swift" }.map(\.path).sorted()
      let compilation = try compiler(
        [
          "-emit-module", "-parse-as-library", "-swift-version", "6",
          "-package-name", "KenshikiOperationBinding", "-module-name",
          "CaptureEvidenceCustody", "-emit-module-path", module.path, "-I", directory.path,
        ] + sources,
        directory: directory)
      XCTAssertEqual(compilation.status, 0, compilation.output)
      guard compilation.status == 0 else { return }

      let supported = """
        import Foundation
        import CaptureEvidenceCustody
        func open(_ configuration: CaptureCustodyConfiguration) throws -> CaptureCustodyRuntime {
          try CaptureCustodyRuntime(configuration: configuration)
        }
        func failureStatus(_ failure: CaptureEvidenceKey.Failure) -> Int32 { failure.status }
        func closeAdmission(_ runtime: CaptureCustodyRuntime) async throws {
          try await runtime.prepareErasure()
        }
        func complete(_ runtime: CaptureCustodyRuntime, workflowID: UUID, at date: Date) async throws {
          let artifact = try CaptureResultArtifact(
            id: UUID(), role: "portrait", mediaType: "image/png", data: Data([1]))
          let saved = try await runtime.store.commitCompletedResult(
            workflowID: workflowID, kind: "consumer-v1", payload: "observation",
            artifacts: [artifact], recordedAt: date, expectedRevision: nil)
          let restored = try await runtime.store.completedResult(
            workflowID: workflowID, kind: "consumer-v1", as: String.self)
          let references = try await runtime.store.completedResults()
          _ = (saved, restored, references)
        }
        """
      let accepted = try consumer(supported, directory: directory)
      XCTAssertEqual(accepted.status, 0, accepted.output)
      guard accepted.status == 0 else { return }

      let rejected = [
        """
        import Foundation
        import CryptoKit
        import CaptureEvidenceCustody
        func unleased(_ url: URL, _ key: SymmetricKey) throws -> CaptureEvidenceStore {
          try CaptureEvidenceStore(directory: url, key: key)
        }
        """,
        """
        import CaptureEvidenceCustody
        func extractKey() throws {
          _ = try CaptureEvidenceKey.loadOrCreate(service: "consumer")
        }
        """,
        """
        import CaptureEvidenceCustody
        func deleteKey() throws {
          try CaptureEvidenceKey.remove(service: "consumer", account: "key", accessGroup: nil)
        }
        """,
        """
        import Foundation
        import KenshikiProtectedStorage
        func exportKey(_ vault: HardwareBoundStoreKeyCustody) throws -> Data {
          try vault.withDatabaseKey(existingCiphertext: true) { Data($0) }
        }
        """,
        """
        import KenshikiProtectedStorage
        func bypassErasure(_ vault: HardwareBoundStoreKeyCustody) throws {
          try vault.destroyAfterCiphertextErasure()
        }
        """,
        """
        import Foundation
        import KenshikiProtectedStorage
        func unregisteredMigration(_ vault: HardwareBoundStoreKeyCustody, key: Data) throws {
          try vault.importLegacyKey(key)
        }
        """,
      ]
      for source in rejected {
        let result = try consumer(source, directory: directory)
        XCTAssertNotEqual(result.status, 0, "Public custody bypass compiled: \(source)")
        XCTAssertTrue(
          result.output.contains("inaccessible due to 'internal' protection level")
            || result.output.contains("inaccessible due to '@_spi' protection level"), result.output)
      }
    }

    private func consumer(_ source: String, directory: URL) throws -> (
      status: Int32, output: String
    ) {
      let file = directory.appendingPathComponent("Consumer.swift")
      try source.write(to: file, atomically: true, encoding: .utf8)
      return try compiler(
        ["-typecheck", "-swift-version", "6", "-I", directory.path, file.path],
        directory: directory)
    }

    private func compiler(_ arguments: [String], directory: URL) throws -> (
      status: Int32, output: String
    ) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      // Compile against the actual SwiftPM dependency artifacts used by this test bundle, including
      // an isolated --scratch-path. The independently compiled consumer still has no testable/SPI
      // access; dependencies are resolved rather than accidentally hidden by the compiler probe.
      let build = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      let dependencies = ["-I", build.appendingPathComponent("Modules").path,
        "-I", build.appendingPathComponent("KenshikiSQLCipherBridge.build").path,
        "-F", build.path]
      process.arguments =
        ["swiftc", "-module-cache-path", directory.appendingPathComponent("cache").path]
        + dependencies + arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit()
      return (process.terminationStatus, output)
    }
  }
#endif
