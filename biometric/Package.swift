// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KenshikiBiometricSDK",
    platforms: [.iOS(.v18), .macOS("13.3")],
    products: [.library(name: "BiometricSDK", targets: ["BiometricSDK"]),
               .library(name: "BiometricCapture", targets: ["BiometricCapture"]),
               .library(name: "BiometricCapturePreview", targets: ["BiometricCapturePreview"]),
               .library(name: "BiometricInference", targets: ["BiometricInference"]),
               .library(name: "BiometricRuntime", targets: ["onnxruntime"])],
    dependencies: [.package(path: "../foundation/motion")],
    targets: [.binaryTarget(name: "onnxruntime", url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.22.0.zip",
                            checksum: "90d9de5a139087a6b05a18125d01d01d198820e1731e6f0f11b38749b2ab181f"),
              .target(name: "AuraFaceNative", dependencies: ["onnxruntime"], path: "cpp",
                      sources: ["src/portrait.cpp", "src/auraface_input.cpp", "src/auraface.cpp", "src/face_alignment.cpp", "src/auraface_bridge.cpp", "src/frame_selection.cpp"],
                      publicHeadersPath: "include"),
              .target(name: "BiometricInference", dependencies: ["BiometricSDK", "AuraFaceNative"], path: "ios/Sources/BiometricInference"),
              .testTarget(name: "InferenceTests", dependencies: ["BiometricInference"], path: "ios/Tests/InferenceTests"),
              .target(name: "BiometricSDK", path: "ios/Sources/BiometricSDK"),
              .target(name: "BiometricCapture", dependencies: ["BiometricSDK",
                  .product(name: "KenshikiMotion", package: "motion")], path: "ios/Sources/BiometricCapture"),
              .target(name: "BiometricCapturePreview", dependencies: ["BiometricCapture"], path: "ios/Sources/BiometricCapturePreview"),
              .testTarget(name: "CaptureTests", dependencies: ["BiometricCapture"], path: "ios/Tests/CaptureTests"),
              .testTarget(name: "QualityGuardsTests", dependencies: ["BiometricSDK"], path: "ios/Tests/QualityGuardsTests"),
              .testTarget(name: "PrimitiveTests", dependencies: ["BiometricSDK"], path: "ios/Tests/PrimitiveTests")],
    cxxLanguageStandard: .cxx20
)
