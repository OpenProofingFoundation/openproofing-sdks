// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KenshikiPassportSDK",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "PassportSDK", targets: ["PassportSDK"]),
        .library(name: "PassportNFC", targets: ["PassportNFC"]),
        .library(name: "PassportMRZCapture", targets: ["PassportMRZCapture"]),
        .library(name: "PassportMRZPreview", targets: ["PassportMRZPreview"])
    ],
    dependencies: [.package(path: "third-party/NFCPassportReader")],
    targets: [
        .target(name: "PassportSDK", path: "ios/Sources/PassportSDK"),
        .target(name: "PassportNFC", dependencies: [
            "PassportSDK",
            .product(name: "NFCPassportReader", package: "NFCPassportReader", condition: .when(platforms: [.iOS]))
        ], path: "ios/Sources/PassportNFC"),
        .target(name: "PassportMRZCapture", dependencies: ["PassportSDK"], path: "ios/Sources/PassportMRZCapture"),
        .target(name: "PassportMRZPreview", dependencies: ["PassportMRZCapture"], path: "ios/Sources/PassportMRZPreview"),
        .testTarget(name: "PassportTests", dependencies: ["PassportSDK"], path: "ios/Tests/PassportTests"),
        .testTarget(name: "PassportNFCTests", dependencies: [
            "PassportSDK", "PassportNFC",
            .product(name: "NFCPassportReader", package: "NFCPassportReader", condition: .when(platforms: [.iOS]))
        ], path: "ios/Tests/PassportNFCTests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CaptureMRZTests", dependencies: ["PassportMRZCapture", "PassportMRZPreview"], path: "ios/Tests/CaptureMRZTests"),
        .testTarget(name: "PassportQualityGuardsTests", dependencies: ["PassportSDK"], path: "ios/Tests/QualityGuardsTests")
    ],
    swiftLanguageModes: [.v6]
)
