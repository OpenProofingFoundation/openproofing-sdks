// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KenshikiFaceQuality",
    platforms: [.iOS(.v18), .macOS("13.3")],
    products: [.library(name: "BiometricQuality", targets: ["BiometricQuality"])],
    dependencies: [.package(path: "..")],
    targets: [
        .binaryTarget(name: "OFIQNative", path: ".build/native-quality/OFIQNative.xcframework"),
        .target(name: "BiometricQuality", dependencies: [
            .product(name: "BiometricSDK", package: "biometric"),
            .product(name: "BiometricRuntime", package: "biometric"), "OFIQNative"],
            linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z")]),
        .testTarget(name: "QualityTests", dependencies: ["BiometricQuality"])
    ]
)
