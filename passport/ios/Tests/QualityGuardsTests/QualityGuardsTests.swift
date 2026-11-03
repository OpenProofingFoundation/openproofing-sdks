#if os(macOS)
import Foundation
import XCTest

/// Like the identity SDK, local swift test enforces the boundary; no missing-script skip.
final class QualityGuardsTests: XCTestCase {
    func testRepositoryQualityGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/quality.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "Quality entry point must exist")
        let process = Process()
        let executable = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("python3") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        process.executableURL = try XCTUnwrap(executable, "python3 must be available on PATH")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Repository guards failed:\n\(output)")
    }
}
#endif
