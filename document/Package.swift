// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KenshikiDocumentSDK",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "DocumentSDK", targets: ["DocumentSDK"]),
        .library(name: "DocumentCaptureApple", targets: ["DocumentCaptureApple"]),
        .library(name: "DocumentCapturePreview", targets: ["DocumentCapturePreview"]),
        .library(name: "DocumentCaptureJournal", targets: ["DocumentCaptureJournal"]),
        .library(name: "DocumentCapture", targets: ["DocumentCapture"]),
    ],
    dependencies: [.package(name: "KenshikiFoundation", path: "..")],
    targets: [
        .binaryTarget(name: "DocumentOpenCVBridge", path: ".build/native/DocumentOpenCVBridge.xcframework"),
        .target(name: "DocumentSDK", path: "ios/Sources/DocumentSDK"),
        .target(name: "DocumentCaptureApple", dependencies: ["DocumentSDK", "DocumentOpenCVBridge"], path: "ios/Sources/DocumentCaptureApple"),
        .target(name: "DocumentCapturePreview", dependencies: ["DocumentCaptureApple", "DocumentSDK"], path: "ios/Sources/DocumentCapturePreview"),
        .target(name: "DocumentCaptureJournal", dependencies: ["DocumentSDK", "DocumentCaptureApple", .product(name: "CaptureEvidenceCustody", package: "KenshikiFoundation")], path: "ios/Sources/DocumentCaptureJournal"),
        .target(name: "DocumentCapture", dependencies: ["DocumentSDK", "DocumentCaptureApple", "DocumentCaptureJournal", .product(name: "CaptureEvidenceCustody", package: "KenshikiFoundation"), .product(name: "KenshikiEvidenceManifest", package: "KenshikiFoundation")], path: "ios/Sources/DocumentCapture"),
        .testTarget(name: "DocumentCoreTests", dependencies: ["DocumentSDK"], path: "ios/Tests/CoreTests"),
        .testTarget(name: "DocumentAppleTests", dependencies: ["DocumentSDK", "DocumentCaptureApple", "DocumentCapturePreview"], path: "ios/Tests/AppleTests"),
        .testTarget(name: "DocumentJournalTests", dependencies: ["DocumentCaptureJournal", "DocumentCaptureApple", .product(name: "CaptureEvidenceCustody", package: "KenshikiFoundation")], path: "ios/Tests/JournalTests"),
        .testTarget(name: "DocumentCaptureTests", dependencies: ["DocumentCapture", "DocumentCaptureApple", "DocumentCaptureJournal", .product(name: "CaptureEvidenceCustody", package: "KenshikiFoundation")], path: "ios/Tests/CaptureTests"),
        .testTarget(name: "DocumentQualityGuardsTests", dependencies: ["DocumentSDK"], path: "ios/Tests/QualityGuardsTests"),
    ],
    cxxLanguageStandard: .cxx20
)
