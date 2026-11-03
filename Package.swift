// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "KenshikiOperationBinding",
  platforms: [.macOS(.v13), .iOS("18.0")],
  products: [.library(name: "CaptureEvidenceCustody", targets: ["CaptureEvidenceCustody"]),.library(name: "KenshikiOperationBinding", targets: ["KenshikiOperationBinding"]),
    .library(name: "KenshikiProtectedStorage", targets: ["KenshikiProtectedStorage"]),
    .library(name: "KenshikiEvidenceManifest", targets: ["KenshikiEvidenceManifest"]),
    .library(name: "KenshikiPulsePassport", targets: ["KenshikiPulsePassport"])],
  dependencies: [.package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", revision: "39f212458aeb88e33bdac2200a793a3f0d55d32b")],
  targets: [
    .target(name: "CaptureEvidenceCustody", dependencies: ["KenshikiProtectedStorage", "KenshikiEvidenceManifest"], path: "foundation/Sources/CaptureEvidenceCustody"),
    .testTarget(name: "CaptureEvidenceCustodyTests", dependencies: ["CaptureEvidenceCustody", "KenshikiProtectedStorage", "KenshikiEvidenceManifest"], path: "foundation/Tests/CaptureEvidenceCustodyTests"),
    .target(name: "KenshikiPulsePassport", dependencies: ["KenshikiOperationBinding"], path: "services/pulse/Sources/KenshikiPulsePassport"),
    .testTarget(name: "KenshikiPulsePassportTests", dependencies: ["KenshikiPulsePassport", "KenshikiOperationBinding"], path: "services/pulse/Tests/KenshikiPulsePassportTests"),
    .target(name: "KenshikiEvidenceManifest", path: "foundation/Sources/KenshikiEvidenceManifest"),
    .testTarget(name: "KenshikiEvidenceManifestTests", dependencies: ["KenshikiEvidenceManifest"], path: "foundation/Tests/KenshikiEvidenceManifestTests"),
    .target(name: "KenshikiSQLCipherBridge", dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")], path: "foundation/Sources/KenshikiSQLCipherBridge", cSettings: [.define("SQLITE_HAS_CODEC", to: "1")]),
    .target(name: "KenshikiProtectedStorage", dependencies: ["KenshikiSQLCipherBridge", .product(name: "SQLCipher", package: "SQLCipher.swift")], path: "foundation/Sources/KenshikiProtectedStorage"),
    .testTarget(name: "KenshikiProtectedStorageTests", dependencies: ["KenshikiProtectedStorage", .product(name: "SQLCipher", package: "SQLCipher.swift")], path: "foundation/Tests/KenshikiProtectedStorageTests"),
    .target(name: "KenshikiOperationBinding", dependencies: ["KenshikiProtectedStorage", .product(name: "SQLCipher", package: "SQLCipher.swift")], path: "foundation/Sources/KenshikiOperationBinding"),
    .testTarget(name: "KenshikiOperationBindingTests", dependencies: ["KenshikiOperationBinding", "KenshikiProtectedStorage", .product(name: "SQLCipher", package: "SQLCipher.swift")],
      path: "foundation/Tests/KenshikiOperationBindingTests"),
  ]
)
