// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "KenshikiOperationBinding",
  platforms: [.macOS(.v13), .iOS("18.0")],
  products: [.library(name: "CaptureEvidenceCustody", targets: ["CaptureEvidenceCustody"]),
    .library(name: "KenshikiOperationBinding", targets: ["KenshikiOperationBinding"]),
    .library(name: "KenshikiProtectedStorage", targets: ["KenshikiProtectedStorage"]),
    .library(name: "KenshikiEvidenceManifest", targets: ["KenshikiEvidenceManifest"])],
  dependencies: [.package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", revision: "39f212458aeb88e33bdac2200a793a3f0d55d32b")],
  targets: [
    .target(name: "CaptureEvidenceCustody", dependencies: ["KenshikiProtectedStorage", "KenshikiEvidenceManifest"]),
    .testTarget(name: "CaptureEvidenceCustodyTests", dependencies: ["CaptureEvidenceCustody", "KenshikiProtectedStorage", "KenshikiEvidenceManifest"]),
    .target(name: "KenshikiEvidenceManifest"),
    .testTarget(name: "KenshikiEvidenceManifestTests", dependencies: ["KenshikiEvidenceManifest"]),
    .target(name: "KenshikiSQLCipherBridge", dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")], cSettings: [.define("SQLITE_HAS_CODEC", to: "1")]),
    .target(name: "KenshikiProtectedStorage", dependencies: ["KenshikiSQLCipherBridge", .product(name: "SQLCipher", package: "SQLCipher.swift")]),
    .testTarget(name: "KenshikiProtectedStorageTests", dependencies: ["KenshikiProtectedStorage", .product(name: "SQLCipher", package: "SQLCipher.swift")]),
    .target(name: "KenshikiOperationBinding", dependencies: ["KenshikiProtectedStorage", .product(name: "SQLCipher", package: "SQLCipher.swift")]),
    .testTarget(name: "KenshikiOperationBindingTests", dependencies: ["KenshikiOperationBinding", "KenshikiProtectedStorage", .product(name: "SQLCipher", package: "SQLCipher.swift")]),
  ]
)
